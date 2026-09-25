## The ``users`` table (schema version 6): who each ``owner_uid`` is.
##
## ``executions.owner_uid`` is an integer -- the uid on POSIX, the SID's hash
## on Windows (``runquota_core/owner_id``). This table records, once per
## owner, the principal that integer was derived from and a human-readable
## name for it, so a reader of a store never has to reverse a hash to learn
## whose rows it is looking at.
##
## Three rules, and the schema enforces the first two rather than trusting
## this module to:
##
## * **The key never changes, and neither does its preimage.** A second
##   principal under an existing ``owner_uid`` is a hash collision; the
##   ``users_principal_is_immutable`` trigger aborts the write that would
##   record it, so two users can never silently come to share a scope.
## * **Every recorded owner has a row.** ``executions_owner_is_a_user``
##   refuses an execution whose ``owner_uid`` names no ``users`` row, so the
##   daemon records the owner before any execution that references it.
## * **The name is refreshed, never erased.** Accounts get renamed. When the
##   daemon resolves a different name for a connecting principal than the
##   one stored, the name is replaced and ``name_updated_at_unix_millis``
##   stamped; ``owner_uid`` is untouched. A principal that no longer resolves
##   -- a deleted account, an unreachable domain -- KEEPS its last known
##   name: an upsert carrying no name never overwrites one.
##
## The rows come from PEER CREDENTIALS, as ``owner_uid`` does. The daemon
## derives the principal from the connection, not from anything the client
## sent; this module only stores what it is handed.

import std/[options, strutils]

import ./sqlite_cli, ./store, ./types

const usersColumns = [
  "owner_uid", "principal_kind", "principal", "name",
  "first_seen_at_unix_millis", "name_updated_at_unix_millis"]

proc encodeOptionalText(value: Option[string]): string =
  if value.isNone: "null" else: encodeText(value.get)

proc userUpsertStatement*(ownerUid: int64; kind: PrincipalKind;
                          principal: string; name: Option[string];
                          atUnixMillis: int64): string =
  ## Records that the principal ``principal`` owns ``ownerUid``, seen at
  ## ``atUnixMillis`` with display name ``name`` (none: it did not resolve).
  ##
  ## * An owner not yet in the table is inserted, first seen now.
  ## * An owner already there with the SAME principal has its name replaced
  ##   only when ``name`` is some AND differs from the stored one, and then
  ##   ``name_updated_at_unix_millis`` becomes ``atUnixMillis``. Otherwise
  ##   the statement changes nothing -- which is what keeps a deleted
  ##   account's last known name.
  ## * An owner already there with a DIFFERENT principal is a collision.
  ##   The update then names the new principal, and the immutability
  ##   trigger aborts it. That is deliberate: a collision must fail loudly,
  ##   and a ``where`` that merely skipped it would let the second
  ##   principal's executions land under the first one's scope.
  let nameText = encodeOptionalText(name)
  "insert into users (" & usersColumns.join(", ") & ") values (" &
    encodeInt(ownerUid) & ", " & encodeText($kind) & ", " &
    encodeText(principal) & ", " & nameText & ", " &
    encodeInt(atUnixMillis) & ", " &
    (if name.isSome: encodeInt(atUnixMillis) else: "null") & ")" &
    " on conflict (owner_uid) do update set" &
    " principal_kind = excluded.principal_kind," &
    " principal = excluded.principal," &
    " name = coalesce(excluded.name, users.name)," &
    " name_updated_at_unix_millis = case" &
    " when excluded.name is not null and users.name is not excluded.name" &
    " then excluded.first_seen_at_unix_millis" &
    " else users.name_updated_at_unix_millis end" &
    " where users.principal_kind is not excluded.principal_kind" &
    " or users.principal is not excluded.principal" &
    " or (excluded.name is not null and users.name is not excluded.name);"

proc recordUser*(store: ObservationStore; ownerUid: int64;
                 kind: PrincipalKind; principal: string;
                 name: Option[string]; atUnixMillis = 0'i64): bool =
  ## ``userUpsertStatement`` applied to ``store`` directly. The daemon goes
  ## through the background writer instead (``enqueueUserRecord``); this is
  ## for tools, fixtures and tests. Returns false, with the reason in
  ## ``store.lastError``, when the schema refused it -- a collision among
  ## them.
  let now = if atUnixMillis > 0: atUnixMillis else: unixMillisNow()
  store.runStatement(userUpsertStatement(ownerUid, kind, principal, name,
    now))

proc readUsers*(store: ObservationStore): seq[UserRow] =
  ## Every owner, by ``owner_uid``.
  let sql = "select " & [
    selectInt("owner_uid"), selectText("principal_kind"),
    selectText("principal"), selectText("name"),
    selectInt("first_seen_at_unix_millis"),
    selectInt("name_updated_at_unix_millis")
  ].join(" || '|' || ") & " from users order by owner_uid;"
  for row in store.runQuery(sql):
    if row.len != 6:
      continue
    result.add(UserRow(
      ownerUid: parseBiggestInt(row[0]),
      principalKind: parseEnum[PrincipalKind](decodeText(row[1])),
      principal: decodeText(row[2]),
      name: if row[3].isNullField: none(string) else: some(decodeText(row[3])),
      firstSeenAtUnixMillis: parseBiggestInt(row[4]),
      nameUpdatedAtUnixMillis:
        if row[5].isNullField: none(int64) else: some(parseBiggestInt(row[5]))))

proc userRow*(store: ObservationStore; ownerUid: int64): Option[UserRow] =
  ## The row for ``ownerUid``, if there is one.
  for row in store.readUsers():
    if row.ownerUid == ownerUid:
      return some(row)
  none(UserRow)

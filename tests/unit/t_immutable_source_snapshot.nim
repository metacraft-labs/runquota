import std/[os, osproc, tempfiles, unittest]

when defined(posix):
  const
    Script = currentSourcePath().parentDir().parentDir().parentDir() /
      "scripts" / "check_immutable_source.sh"
    ReadOnlyDir = {fpUserRead, fpUserExec, fpGroupRead, fpGroupExec,
      fpOthersRead, fpOthersExec}

  proc inspectFixture(kind: string): tuple[output: string, exitCode: int] =
    let root = createTempDir("rq-immutable-", "")
    let source = root / "source"
    createDir(source)
    defer:
      setFilePermissions(source, ReadOnlyDir + {fpUserWrite})
      removeDir(root)
    writeFile(source / "input", "fixture")
    setFilePermissions(source / "input", {fpUserRead, fpGroupRead, fpOthersRead})
    case kind
    of "internal-link":
      createSymlink("input", source / "alias")
    of "writable-file":
      setFilePermissions(source / "input", {fpUserRead, fpUserWrite})
    of "writable-target":
      writeFile(root / "outside", "mutable")
      createSymlink("../outside", source / "alias")
    of "dangling-link":
      createSymlink("missing", source / "alias")
    of "cycle":
      createSymlink(".", source / "cycle")
    else:
      discard
    if kind != "writable-directory":
      setFilePermissions(source, ReadOnlyDir)
    execCmdEx(quoteShell(findExe("bash")) & " " & quoteShell(Script) &
      " " & quoteShell(source))

  suite "immutable source snapshot":
    test "read-only files and directories pass":
      check inspectFixture("plain").exitCode == 0
    test "an internal symlink to a read-only file passes":
      check inspectFixture("internal-link").exitCode == 0
    test "writable files are rejected":
      check inspectFixture("writable-file").exitCode != 0
    test "writable directories are rejected":
      check inspectFixture("writable-directory").exitCode != 0
    test "a symlink to a writable target is rejected":
      check inspectFixture("writable-target").exitCode != 0
    test "dangling symlinks are rejected":
      check inspectFixture("dangling-link").exitCode != 0
    test "traversal cycles fail closed":
      check inspectFixture("cycle").exitCode != 0
else:
  suite "immutable source snapshot":
    test "source permission regression requires POSIX":
      skip()

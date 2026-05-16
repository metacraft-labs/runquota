# Crash Recovery

`t_e2e_runquota_client_exit_releases_lease.nim` starts the real daemon and
uses real local IPC clients. It verifies explicit release, normal supervisor
exit, abnormal supervisor exit, and started/running lease cleanup without
mocking the daemon, client library, or socket transport.

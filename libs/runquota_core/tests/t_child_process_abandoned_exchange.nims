# Compiles `runquota_core/child_process`'s test-only fault injection into this
# test binary alone; see the header of `t_child_process_abandoned_exchange.nim`.
switch("define", "runquotaChildProcessFaults")

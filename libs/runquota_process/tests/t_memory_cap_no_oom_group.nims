# This test stands for a kernel without `memory.oom.group` (Linux 4.5 to
# 4.18): the launcher is compiled to look for that file under a name that
# does not exist (`runquotaHideMemoryFile`), so opening it fails with
# ENOENT exactly as it does on such a kernel.
switch("define", "runquotaHideMemoryFile=memory.oom.group")

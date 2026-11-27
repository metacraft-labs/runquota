# This test stands for a kernel without `memory.peak` (before Linux 5.19):
# the launcher is compiled to look for that file under a name that does not
# exist (`runquotaHideMemoryFile`), so reading it fails with ENOENT exactly
# as it does on such a kernel.
switch("define", "runquotaHideMemoryFile=memory.peak")

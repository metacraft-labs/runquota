## No mocks: /proc/stat is a byte format, and this tests its parser directly.
## Live host capacity and saturation checks remain in t_host_load_reading_invariants.
import std/unittest
import runquota_observation_store/linux_cpu_ticks

suite "Linux CPU accounting":
  test "guest time is already included in user and nice":
    let sample = parseLinuxCpuTicks("cpu  100 20 30 400 50 6 7 8 60 10\n")
    check sample.busy == 171
    check sample.idle == 450
    let noGuests = parseLinuxCpuTicks("cpu 100 20 30 400 50 6 7 8 0 0\n")
    check sample == noGuests

  test "older kernels can omit trailing fields":
    let sample = parseLinuxCpuTicks("cpu 100 20 30 400\n")
    check sample.busy == 150
    check sample.idle == 400

  test "only the aggregate line contributes":
    let sample = parseLinuxCpuTicks("cpu 100 20 30 400\ncpu0 100 20 30 400\n")
    check sample.busy == 150
    check sample.idle == 400
    check parseLinuxCpuTicks("cpu0 100 20 30 400\n") == LinuxCpuTicks()

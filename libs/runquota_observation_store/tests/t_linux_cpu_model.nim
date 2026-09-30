## No mocks: these are inputs to the real /proc/cpuinfo parser, using the
## format emitted by Linux arch/arm64/kernel/cpuinfo.c, c_show. Parser cases
## cover architectures unavailable to a given test host. The existing native
## host-profile and degraded-capture integration tests still require detection
## and storage of a real non-unknown model on the machine running the suite.
import std/[strutils, unittest]
import runquota_observation_store/linux_cpu_model

const
  armCpu = """processor : 0
BogoMIPS : 2000.00
Features : fp asimd
CPU implementer : 0x41
CPU architecture: 8
CPU variant : 0x3
CPU part : 0xd0c
CPU revision : 1
"""
  armModel = "ARM implementer 0x41 part 0xd0c variant 0x3 revision 1"

suite "Linux CPU model identity":
  test "ARM64 MIDR fields identify a processor without a model name":
    check linuxCpuModel(armCpu) == armModel

  test "textual model names retain priority":
    check linuxCpuModel("model name : Example x86 CPU\n" & armCpu) ==
      "Example x86 CPU"
    check linuxCpuModel("Hardware : Example legacy ARM CPU\n") ==
      "Example legacy ARM CPU"

  test "equivalent processors do not repeat the identity":
    check linuxCpuModel(armCpu & "\n" & armCpu.replace("processor : 0",
      "processor : 1")) == armModel

  test "heterogeneous processors have stable ordering":
    let other = armCpu.replace("0xd0c", "0xd05")
    let expected = armModel.replace("0xd0c", "0xd05") & "; " & armModel
    check linuxCpuModel(armCpu & "\n" & other) == expected
    check linuxCpuModel(other & "\n" & armCpu) == expected

  test "every MIDR identity field contributes":
    for value in [armCpu.replace("0x41", "0x42"),
                  armCpu.replace("0xd0c", "0xd0d"),
                  armCpu.replace("0x3", "0x4"),
                  armCpu.replace("revision : 1", "revision : 2")]:
      check linuxCpuModel(value) != armModel

  test "whitespace and hexadecimal spelling do not alter identity":
    check linuxCpuModel(armCpu.replace(" : ", "\t: \t").replace(
      "\n", "\r\n").replace("0xd0c", "0xD0C")) == armModel

  test "missing optional revision fields do not invent values":
    check linuxCpuModel("CPU implementer: 0x41\nCPU part: 0xd0c\n") ==
      "ARM implementer 0x41 part 0xd0c"

  test "incomplete processors cannot borrow identity fields from each other":
    check linuxCpuModel("CPU implementer: 0x41\n\nCPU part: 0xd0c\n") == ""
    check linuxCpuModel("CPU implementer: 0x41\n\n" & armCpu) == armModel

  test "absent or malformed identities remain unknown":
    for value in ["", "processor: 0\nFeatures: fp asimd\n",
                  armCpu.replace("0x41", "0x141"),
                  armCpu.replace("0x41", "0x10000000000000041"),
                  armCpu.replace("0xd0c", "0xunknown"),
                  armCpu.replace("0xd0c", "0xffffffffffffffffffff")]:
      check linuxCpuModel(value) == ""

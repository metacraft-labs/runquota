## Mount parsing uses fixed kernel-format inputs. The sysfs fixture uses real
## files and symlinks because a test host cannot switch its root disk between
## NVMe, MMC and HDD. Only the sysfs root is injected; production resolution
## and reads run unchanged. The native host-profile test also uses live sysfs.
import std/[os, unittest]
import runquota_observation_store/[linux_storage, types]

suite "Linux storage identity":
  test "mount device numbers survive aliases and escaped mount points":
    let mounts = "1 0 259:1 / / rw - ext4 /dev/root rw\n" &
      "2 1 8:2 / /data\\040files rw - ext4 UUID=example rw\n"
    check linuxMountForPath(mounts, "/tmp/work").deviceNumber == "259:1"
    check linuxMountForPath(mounts, "/data files/a").deviceNumber == "8:2"
    check linuxMountForPath(mounts, "/data files-other/a").deviceNumber == "259:1"

  when defined(posix):
    test "sysfs resolves partitions without stripping disk-number suffixes":
      let root = getTempDir() / ("rq-sysfs-" & $getCurrentProcessId())
      createDir(root / "dev")
      defer: removeDir(root)
      for entry in [("259:1", "nvme0n1", "nvme0n1p1", "0", dcNvme),
                    ("179:1", "mmcblk0", "mmcblk0p1", "0", dcSsd),
                    ("8:1", "sda", "sda1", "1", dcHdd)]:
        let disk = root / entry[1]
        let partition = disk / entry[2]
        createDir(disk / "queue")
        createDir(partition)
        writeFile(disk / "queue/rotational", entry[3] & "\n")
        writeFile(partition / "partition", "1\n")
        createSymlink(partition, root / "dev" / entry[0])
        check linuxBlockDiskClass(entry[0], root / "dev") == entry[4]
      check linuxBlockDiskClass("0:42", root / "dev") == dcUnknown
      check linuxBlockDiskClass("../disk", root / "dev") == dcUnknown

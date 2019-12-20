Dual rootfs partitioner
=======================

This repository hosts a [Mender Update
Module](https://github.com/mendersoftware/mender/blob/master/Documentation/update-modules-v3-file-api.md)
which can repartition a live system into a dual partition layout compatible with
[Mender](https://github.com/mendersoftware/mender).

**Warning:** This Update Module is _highly_ experimental, and if the operation
fails or is interrupted your device can easily get **bricked**. Do not attempt
to use it in production unless you are prepared to deal with this situation.


Platform support
----------------

This Update Module has only been tested with **Beaglebone Black**, and will
almost certainly not work on any other board. However, the general approach is
applicable to a wide array of different boards, and it should be possible to
adapt the Update Module and Artifact to other boards with only a modest
effort. There is some level of skill required to do this, but most people who
have at least some experience with boot loaders and the Linux boot process
should be able to work it out.


Prerequisites
-------------

### On the build host

#### System packages

* Docker
* GCC
* GCC for ARM (if you want to build for ARM)

On Ubuntu, these can be installed with:

```bash
sudo apt install docker.io build-essential crossbuild-essential-armhf
sudo usermod -a -G docker $USER
```

(note that you may need to log out and back in again to get Docker to work)

#### Mender tools

* `mender-artifact` tool (downloadable from [Mender
    website](https://docs.mender.io/downloads))
* _Optional:_ `single-file-artifact-gen` tool (Downloadable from [Mender client
    repository](https://raw.githubusercontent.com/mendersoftware/mender/master/support/modules-artifact-gen/single-file-artifact-gen))

The tools need to be in the `PATH`

### On the device

On the device you only need a running embedded Linux distribution. In theory any
compatible distribution should work, but in practice there may be small tweaks
and adjustments needed unless you run the one that this module was tested with.

The module was tested with these two images, downloaded from [the Beagleboard
website](https://beagleboard.org/latest-images):

*  [`bone-debian-9.5-iot-armhf-2018-10-07-4gb.img.xz`](https://debian.beagleboard.org/images/bone-debian-9.5-iot-armhf-2018-10-07-4gb.img.xz)
* [`bone-debian-9.4-iot-armhf-2018-06-17-4gb.img.xz`](http://debian.beagleboard.org/images/bone-debian-9.4-iot-armhf-2018-06-17-4gb.img.xz)


Preparing Artifacts
-------------------

1. Install the Update Module on the device. This can be accomplished in one of
   two ways:

  1. Install using SSH/SCP:

     ```bash
     scp src/dual-rootfs-repartition <USER>@<DEVICE-IP>:.
     ssh <USER>@<DEVICE-IP> sudo cp dual-rootfs-repartition /usr/share/mender/modules/v3
     ```

  2. Install using an Artifact. This requires that the Update Module
     `single-file` is already installed on the device.

     ```bash
     ./build-module-artifact -o dual-rootfs-partition-module.mender
     ```

     Then install this Artifact on the device using the UI.

2. Create an Artifact which will perform the live dual rootfs repartitioning:

   ```bash
   ./build-repartition-artifact --arm -- -o dual-rootfs-partition.mender
   ```


Installing the Artifact
-----------------------

After the Artifact has been prepared, it can be installed like any other
Artifact from the Mender UI.

During the install, the device is likely to spend a long time inside the
"Reboot" stage of the install. This is because the device has to transfer into
running from RAM in order to repartition the storage, and therefore it has to
shut down the running system. During this time you will not see any logs or
output in the UI (but see "Debugging tips" below).


Caveats
-------

The Update Module will currently not work if Mender is run in standalone
mode. This is because standalone mode does not support custom `ArtifactReboot`
functions, which the Update Module uses extensively to do its job.


Debugging tips
--------------

When the Update Module shuts down the system, output will no longer go to the
logs, because there is nowhere to store these logs (it is running from
RAM). However, it is possible to force the output to go to a certain terminal,
and you can monitor this terminal for progress and error messages yourself.

To do so, log in to the device using either a physical screen or a serial
cable. It can not be SSH, because SSH will be killed during the shutdown. Once
there, execute this command to see which terminal you are in:

```bash
tty
```

Example result:

```bash
/dev/ttyS0
```

You can specify this terminal as an argument when building the Artifact to have
it send all output to that terminal. In the `build-repartition-artifact` from
earlier, specify the `--debug-tty` argument, like this:

```bash
./build-repartition-artifact --arm --debug-tty /dev/ttyS0 -- -o dual-rootfs-partition.mender
```

Then the Update Module will send all output to that terminal.

If you also run the command below on the device, before starting the update,
this provides a good way to see most of the output generated. It will start by
outputting the logs, and once systemd is killed, the Update Module switches to
using the terminal directly.

```bash
journalctl -u mender-client -f
```

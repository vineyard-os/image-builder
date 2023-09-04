#!/usr/bin/python3

import argparse
import os

import yaml


class Emitter:
    args: argparse.Namespace

    def __init__(self, _args):
        self.args = _args

    def emitHeader(self):
        print("#!/bin/bash")

    def emitFooter(self):
        pass

    def emit(self, cmd: str):
        print(cmd)

    def emitElevated(self, cmd: str):
        if self.args.elevator:
            cmd = self.args.elevator + cmd
        print(cmd)

    def emitComment(self, comment: str):
        print("# {}".format(comment))


class FS:
    start: int
    size: int

    def __init__(self, num, yml, cfg):
        self._yaml = yml
        self.num = num
        self.cfg = cfg
        self.partfile = "{}.{}".format(self.cfg.imgfile, self.num)
        self.label = self._yaml['label']
        self.fs = self._yaml['fs']

    @property
    def bootable(self):
        if 'bootable' in self._yaml and self._yaml['bootable'] is True:
            return True
        else:
            return False

    @property
    def content(self):
        if 'content' in self._yaml and self._yaml['content']:
            if os.path.isdir(self._yaml['content']):
                return self._yaml['content']
            else:
                raise RuntimeError('specified content directory {} doesn\'t exist'.format(self._yaml['content']))
        else:
            return None

    @property
    def dd_required(self):
        return True

    def step_bootable(self):
        if self.bootable:
            self.cfg.emitter.emit("parted {} -s -a minimal toggle {} boot".format(self.cfg.imgfile, self.num + 1))

    def step_create_partfile(self):
        if self.dd_required:
            if self.cfg.args.reuse_partitions:
                self.cfg.emitter.emit("dd if={} of={} bs=512 skip={} count={} conv=notrunc status=none".format(self.cfg.imgfile,
                                                                                               self.partfile,
                                                                                               self.start,
                                                                                               self.size))
            else:
                self.cfg.emitter.emit('dd if=/dev/zero of={} bs=512 count={} status=none'.format(self.partfile, self.size))

    def step_modify(self):
        if self.dd_required:
            self.cfg.emitter.emit("dd if={} of={} bs=512 seek={} count={} conv=notrunc status=none".format(self.partfile,
                                                                                           self.cfg.imgfile,
                                                                                           self.start, self.size))

    def step_rsync(self):
        rsync_cmd = "rsync --recursive {}/* {}".format(self.content, self.cfg.args.temp_mount_dir)
        if self.cfg.args.elevator:
            rsync_cmd = self.cfg.args.elevator + " " + rsync_cmd
        self.cfg.emitter.emit(rsync_cmd)

    def step_umount(self):
        umount_cmd = "umount {}".format(self.cfg.args.temp_mount_dir)
        if self.cfg.args.elevator:
            umount_cmd = self.cfg.args.elevator + " " + umount_cmd
        self.cfg.emitter.emit(umount_cmd)


class FAT32(FS):
    def step_image(self):
        self.cfg.emitter.emit("parted {} -s -a minimal mkpart {} fat32 {}s {}s".format(self.cfg.imgfile, self.label,
                                                                                       self.start,
                                                                                       self.start + self.size - 1))

    def step_format(self):
        self.cfg.emitter.emit('mkfs.fat -F32 -s 1 {}'.format(self.partfile))

    def step_mount(self):
        if self.dd_required:
            mount_cmd = "mount -t vfat {} {} -o loop".format(self.partfile,
                                                             self.cfg.args.temp_mount_dir)
        else:
            mount_cmd = "mount -t vfat {} {} -o loop,offset={}".format(self.cfg.imgfile,
                                                                       self.cfg.args.temp_mount_dir,
                                                                       self.start * 512)
        if self.cfg.args.elevator:
            mount_cmd = self.cfg.args.elevator + " " + mount_cmd
        self.cfg.emitter.emit(mount_cmd)

    def step_create(self):
        # Rootless
        if self.content is not None:
            assert not self.cfg.args.mount
            for path, subdirs, files in os.walk(self.content):
                for name in subdirs:
                    self.cfg.emitter.emit('mmd -i {} ::/{}'.format(self.partfile,
                                                                   os.path.join(path, name)[len(self.content):]))

                for name in files:
                    self.cfg.emitter.emit('mcopy -i {} {} ::/{}'.format(self.partfile, os.path.join(path, name),
                                                                        os.path.join(path, name)[len(self.content):]))

    @property
    def dd_required(self):
        return not (self.cfg.args.mount and self.cfg.args.skip_format)

    def mkdir(self, dest: str):
        self.cfg.emitter.emit('mmd -i {} ::/{}; true > /dev/null 2>&1'.format(self.partfile, dest))

    def add_file(self, path: str, dest: str):
        self.cfg.emitter.emit('mcopy -i {} {} ::/{}'.format(self.partfile, path, dest))


class Btrfs(FS):
    def step_image(self):
        self.cfg.emitter.emit(
            "parted {} -s -a minimal mkpart {} btrfs {}s {}s".format(self.cfg.imgfile, self.label, self.start,
                                                                     self.start + self.size - 1))

    def step_create(self):
        content_string = ''
        if self.content:
            content_string = '-r {} '.format(self.content)
        assert not self.cfg.args.mount and not self.cfg.args.skip_format
        self.cfg.emitter.emit('mkfs.btrfs -q -L {} {}{}'.format(self.label, content_string, self.partfile))


class NRFS(FS):
    def step_image(self):
        self.cfg.emitter.emit(
            "sgdisk {} --new {}:{}:{} --typecode {}:f752bf42-7b96-4c3a-9685-ad8497dca74c --change-name {}:{}".format(
                self.cfg.imgfile, self.num + 1, self.start, self.start + self.size - 1, self.num + 1, self.num + 1,
                self.label))

    def step_create(self):
        content_string = ''
        if self.content:
            content_string = '-f -d {}'.format(self.content)
        assert not self.cfg.args.mount and not self.cfg.args.skip_format
        self.cfg.emitter.emit('nrfs-tool make {} {}'.format(content_string, self.partfile))


class Image:
    def __init__(self, yml, cfg):
        self._yaml = yml
        self.cfg = cfg

    def build(self):
        self.cfg.emitter.emit(
            'dd if=/dev/zero of={} bs=1{} count={} status=none'.format(self.cfg.imgfile, self._yaml['size'][-1],
                                                                       self._yaml['size'][:-1]))
        if self._yaml['type'] == 'gpt':
            self.cfg.emitter.emit('parted {} -s -a minimal mktable gpt'.format(self.cfg.imgfile))
        else:
            raise RuntimeError('unknown partition type {}'.format(self._yaml['type']))


class Config:
    def __init__(self, _config, _args, _emitter: Emitter):
        self._yaml = _config
        self.args = _args
        self.emitter = _emitter
        self.disk_sectors = size_to_sectors(_config['size'])
        self.image = Image(_config, self)
        self.partitions = dict()
        self.partition_start = 2048

        for num, part in enumerate(self._yaml['partitions']):
            if part['fs'] == 'fat32':
                self.partitions[num] = FAT32(num, part, self)
            elif part['fs'] == 'btrfs':
                self.partitions[num] = Btrfs(num, part, self)
            elif part['fs'] == 'nrfs':
                self.partitions[num] = NRFS(num, part, self)
            else:
                raise RuntimeError('unexpected fs {} in partition {}'.format(part['fs'], num))

            self.partitions[num].start = self.partition_start
            if part['size'] == 'fit':
                assert ((self.partition_start % 2048) == 0)
                self.partitions[num].size = self.disk_sectors - self.partition_start - 2047
            else:
                self.partitions[num].size = size_to_sectors(part['size'])
            self.partition_start += self.partitions[num].size

    @property
    def imgfile(self):
        if self.args.output:
            return self.args.output
        elif 'file' in self._yaml:
            return self._yaml['file']
        else:
            raise RuntimeError('no output file specified')

    def build(self):
        if args.modify is None:
            if not self.args.reuse_partitions:
                self.image.build()
                for num, part in self.partitions.items():
                    self.emitter.emitComment("# create partition {}".format(num))
                    part.step_image()
                    part.step_bootable()
            else:
                assert os.path.exists(self.imgfile)

            for num, part in self.partitions.items():
                part.step_create_partfile()
                if hasattr(part, "step_format") and not self.args.skip_format:
                    self.emitter.emitComment("# format partition {} ({})")
                    part.step_format()
                self.emitter.emitComment("build partition {} ({})".format(num, part.fs))
                if args.mount:
                    part.step_mount()
                    part.step_rsync()
                    part.step_umount()
                else:
                    part.step_create()
        else:
            self.partitions[args.modify].step_modify()

        if args.bootloader:
            assert 'bootloader' in self._yaml and 'name' in self._yaml['bootloader']
            bootloader = self._yaml['bootloader']
            if self._yaml['bootloader']['name'] == 'limine':
                assert 'partition' in bootloader
                partition = bootloader['partition']
                assert isinstance(partition, int)
                limine_bios = os.getenv('LIMINE_BIOS', '/usr/share/limine/limine-bios.sys')
                limine_efi_ia32 = os.getenv('LIMINE_EFI_IA32', '/usr/share/limine/BOOTIA32.EFI')
                limine_efi_x64 = os.getenv('LIMINE_EFI_X64', '/usr/share/limine/BOOTX64.EFI')

                # Create the EFI folder structure
                self.emitter.emitComment("# install limine (EFI and limine-bios.sys)")
                self.partitions[partition].mkdir('EFI')
                self.partitions[partition].mkdir('EFI/BOOT')

                # Copy the EFI files
                self.partitions[partition].add_file(limine_efi_ia32, 'EFI/BOOT/BOOTIA32.EFI')
                self.partitions[partition].add_file(limine_efi_x64, 'EFI/BOOT/BOOTX64.EFI')

                # Copy limine-bios.sys
                self.partitions[partition].add_file(limine_bios, 'limine-bios.sys')

        # Write the partitions to the image
        for num, part in self.partitions.items():
            self.emitter.emitComment("# write partition {} ({})".format(num, part.fs))
            part.step_modify()

        # If we are installing a bootloader, we may need to again modify the image here
        if args.bootloader:
            assert 'bootloader' in self._yaml and 'name' in self._yaml['bootloader']
            if self._yaml['bootloader']['name'] == 'limine':
                limine_command = os.getenv('LIMINE_PATH', 'limine')
                # Run limine to install BIOS bootloader
                self.emitter.emitComment("# install limine (BIOS boot)")
                self.emitter.emit(limine_command + " bios-install " + self.imgfile)

        if args.vmdk:
            assert ('vmdk' in self._yaml or isinstance(args.vmdk, str))
            if isinstance(args.vmdk, str):
                self.emitter.emit("qemu-img convert -f raw -O vmdk {} {}".format(self.imgfile, args.vmdk))
            else:
                self.emitter.emit("qemu-img convert -f raw -O vmdk {} {}".format(self.imgfile, self._yaml['vmdk']))

        if args.vdi:
            assert ('vdi' in self._yaml or isinstance(args.vdi, str))
            if isinstance(args.vdi, str):
                self.emitter.emit("qemu-img convert -f raw -O vdi {} {}".format(self.imgfile, args.vdi))
            else:
                self.emitter.emit("qemu-img convert -f raw -O vdi {} {}".format(self.imgfile, self._yaml['vdi']))


def size_to_sectors(size):
    if size[-1] == 'M':
        return int(size[:-1]) << 11
    elif size[-1] == 'G':
        return int(size[:-1]) << 21
    else:
        raise RuntimeError('invalid size given: {}'.format(size))


parser = argparse.ArgumentParser()
parser.add_argument('file',
                    help='input YAML file')
parser.add_argument('-m', '--modify', type=int)
parser.add_argument('-o', '--output',
                    help='override output file')
parser.add_argument('-b', '--bootloader', action='store_true',
                    help='install bootloader as specified in configuration file')
parser.add_argument('--reuse-partitions', action='store_true',
                    help='reuse partitions in the file (requires them existing first)')
parser.add_argument('--skip-format', action='store_true',
                    help='dont format partitions when possible')
parser.add_argument('--mount', action='store_true',
                    help='mount the partitions instead of using root-less tools (requires rsync)')
parser.add_argument('--temp-mount-dir', action='store', type=str, default="mnt", const=True, nargs='?',
                    help='temporary folder to use for mounting (default \'mnt\')')
parser.add_argument('--dont-create-mount-dir', action='store_true',
                    help='disable creation and deletion of temporary mount folder')
parser.add_argument('--elevator', action='store', type=str, default=False, const=True, nargs='?',
                    help='tool to use to elevate privileges')
parser.add_argument('--vmdk', action='store', type=str, default=False, const=True, nargs='?',
                    help='build a VMDK image')
parser.add_argument('--vdi', action='store', type=str, default=False, const=True, nargs='?',
                    help='build a VDI image')
args = parser.parse_args()

emitter = Emitter(args)

if args.mount and not args.dont_create_mount_dir:
    emitter.emit("mkdir -p {}".format(args.temp_mount_dir))

emitter.emitHeader()
config = Config(yaml.load(open(args.file, 'r'), Loader=yaml.SafeLoader), args, emitter)
config.build()
emitter.emitFooter()

if args.mount and not args.dont_create_mount_dir:
    emitter.emit("rm -r {}".format(args.temp_mount_dir))

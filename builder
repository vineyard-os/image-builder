#!/usr/bin/python3

import argparse
import os
import yaml
import subprocess

class FS:
	def __init__(self, num, yml, cfg):
		self._yaml = yml
		self.num = num
		self.cfg = cfg
		self.partfile = "{}.{}".format(self.cfg.imgfile, self.num)
		self.label = self._yaml['label']
		self.fs = self._yaml['fs']

	@property
	def bootable(self):
		if('bootable' in self._yaml and self._yaml['bootable'] == True):
			return True
		else:
			return False

	@property
	def content(self):
		if('content' in self._yaml and self._yaml['content']):
			if(os.path.isdir(self._yaml['content'])):
				return self._yaml['content']
			else:
				raise RuntimeError('specified content directory {} doesn\'t exist'.format(self._yaml['content']))
		else:
			return None

	def step_bootable(self):
		if(self.bootable):
			print("parted {} -s -a minimal toggle {} boot".format(self.cfg.imgfile, self.num + 1))

class FAT32(FS):
	def step_image(self):
		print("parted {} -s -a minimal mkpart {} fat32 {}s {}s".format(self.cfg.imgfile, self.label, self.start, self.start + self.size - 1))

	def step_create(self):
		print('dd if=/dev/zero of={} bs=512 count={} status=none'.format(self.partfile, self.size))
		print('mkfs.fat -F32 -s 1 {}'.format(self.partfile))

		if (self.content != None):
			if not self.cfg.args.mount:
				# Rootless
					for path, subdirs, files in os.walk(self.content):
						for name in subdirs:
							print('mmd -i {} ::/{}'.format(self.partfile, os.path.join(path, name)[len(self.content):]))

						for name in files:
							print('mcopy -i {} {} ::/{}'.format(self.partfile, os.path.join(path, name), os.path.join(path, name)[len(self.content):]))
			else:
				mount_cmd = "mount -t vfat {} {}".format(self.partfile, self.cfg.args.temp_mount_dir)
				rsync_cmd = "rsync --recursive {}/* {}".format(self.content, self.cfg.args.temp_mount_dir)
				umount_cmd = "umount {}".format(self.cfg.args.temp_mount_dir)
				if self.cfg.args.elevator:
					mount_cmd = self.cfg.args.elevator + " " + mount_cmd
					rsync_cmd = self.cfg.args.elevator + " " + rsync_cmd
					umount_cmd = self.cfg.args.elevator + " " + umount_cmd
				print(mount_cmd)
				print(rsync_cmd)
				print(umount_cmd)

	def step_modify(self):
		print("dd if={} of={} bs=512 seek={} count={} conv=notrunc status=none".format(self.partfile, self.cfg.imgfile, self.start, self.size))

	def mkdir(self, dest: str):
		print('mmd -i {} ::/{}; true > /dev/null 2>&1'.format(self.partfile, dest))

	def add_file(self, path: str, dest: str):
		print('mcopy -i {} {} ::/{}'.format(self.partfile, path, dest))

class Btrfs(FS):
	def step_image(self):
		print("parted {} -s -a minimal mkpart {} btrfs {}s {}s".format(self.cfg.imgfile, self.label, self.start, self.start + self.size - 1))

	def step_create(self):
		print('dd if=/dev/zero of={} bs=512 count={} status=none'.format(self.partfile, self.size))
		content_string = ''
		if(self.content):
			content_string = '-r {} '.format(self.content)
		assert not self.cfg.mount
		print('mkfs.btrfs -q -L {} {}{}'.format(self.label, content_string, self.partfile))

	def step_modify(self):
		print("dd if={} of={} bs=512 seek={} count={} conv=notrunc status=none".format(self.partfile, self.cfg.imgfile, self.start, self.size))

class NRFS(FS):
	def step_image(self):
		print("sgdisk {} --new {}:{}:{} --typecode {}:f752bf42-7b96-4c3a-9685-ad8497dca74c --change-name {}:{}".format(self.cfg.imgfile, self.num + 1, self.start, self.start + self.size - 1, self.num + 1, self.num + 1, self.label))

	def step_create(self):
		print('dd if=/dev/zero of={} bs=512 count={} status=none'.format(self.partfile, self.size))
		content_string = ''
		if(self.content):
			content_string = '-f -d {}'.format(self.content)
		assert not self.cfg.mount
		print('nrfs-tool make {} {}'.format(content_string, self.partfile))

	def step_modify(self):
		print("dd if={} of={} bs=512 seek={} count={} conv=notrunc status=none".format(self.partfile, self.cfg.imgfile, self.start, self.size))

class Image:
	def __init__(self, yml, cfg):
		self._yaml = yml
		self.cfg = cfg

	def build(self):
		print('#!/bin/bash')
		print('dd if=/dev/zero of={} bs=1{} count={} status=none'.format(self.cfg.imgfile, self._yaml['size'][-1], self._yaml['size'][:-1]))
		if(self._yaml['type'] == 'gpt'):
			print('parted {} -s -a minimal mktable gpt'.format(self.cfg.imgfile))
		else:
			raise RuntimeError('unknown partition type {}'.format(self._yaml['type']))

class Config:
	def __init__(self, config, args):
		self._yaml = config
		self.args = args
		self.disk_sectors = size_to_sectors(config['size'])
		self.image = Image(config, self)
		self.partitions = dict()
		self.partition_start = 2048

		for num, part in enumerate(self._yaml['partitions']):
			if(part['fs'] == 'fat32'):
				self.partitions[num] = FAT32(num, part, self)
			elif(part['fs'] == 'btrfs'):
				self.partitions[num] = Btrfs(num, part, self)
			elif(part['fs'] == 'nrfs'):
				self.partitions[num] = NRFS(num, part, self)
			else:
				raise RuntimeError('unexpected fs {} in partition {}'.format(part['fs'], num))

			self.partitions[num].start = self.partition_start
			if(part['size'] == 'fit'):
				assert((self.partition_start % 2048) == 0)
				self.partitions[num].size = self.disk_sectors - self.partition_start - 2047
			else:
				self.partitions[num].size = size_to_sectors(part['size'])
			self.partition_start += self.partitions[num].size

	@property
	def imgfile(self):
		if(self.args.output):
			return self.args.output
		elif('file' in self._yaml):
			return self._yaml['file']
		else:
			raise RuntimeError('no output file specified')

	def build(self):
		if(args.modify == None):
			self.image.build()
			for num, part in self.partitions.items():
				print("# create partition {}".format(num))
				part.step_image()
				part.step_bootable()

			for num, part in self.partitions.items():
				print("# build partition {} ({})".format(num, part.fs))
				part.step_create()
		else:
			self.partitions[args.modify].step_modify()

		if(args.bootloader):
			assert 'bootloader' in self._yaml and 'name' in self._yaml['bootloader']
			bootloader = self._yaml['bootloader']
			if(self._yaml['bootloader']['name'] == 'limine'):
				assert 'partition' in bootloader
				partition = bootloader['partition']
				assert isinstance(partition, int)
				limine_bios = os.getenv('LIMINE_BIOS', '/usr/share/limine/limine-bios.sys')
				limine_efi_ia32 = os.getenv('LIMINE_EFI_IA32', '/usr/share/limine/BOOTIA32.EFI')
				limine_efi_x64 = os.getenv('LIMINE_EFI_X64', '/usr/share/limine/BOOTX64.EFI')

				# Create the EFI folder structure
				print("# install limine (EFI and limine-bios.sys)")
				self.partitions[partition].mkdir('EFI')
				self.partitions[partition].mkdir('EFI/BOOT')

				# Copy the EFI files
				self.partitions[partition].add_file(limine_efi_ia32, 'EFI/BOOT/BOOTIA32.EFI')
				self.partitions[partition].add_file(limine_efi_x64, 'EFI/BOOT/BOOTX64.EFI')

				# Copy limine-bios.sys
				self.partitions[partition].add_file(limine_bios, 'limine-bios.sys')

		# Write the partitions to the image
		for num, part in self.partitions.items():
			print("# write partition {} ({})".format(num, part.fs))
			part.step_modify()

		# If we are installing a bootloader, we may need to again modify the image here
		if(args.bootloader):
			assert 'bootloader' in self._yaml and 'name' in self._yaml['bootloader']
			bootloader = self._yaml['bootloader']
			if(self._yaml['bootloader']['name'] == 'limine'):
				limine_command = os.getenv('LIMINE_PATH', 'limine')
				# Run limine to install BIOS bootloader
				print("# install limine (BIOS boot)")
				print(limine_command + " bios-install " + self.imgfile)

		if(args.vmdk):
			assert('vmdk' in self._yaml or isinstance(args.vmdk, str))
			if(isinstance(args.vmdk, str)):
				print("qemu-img convert -f raw -O vmdk {} {}".format(self.imgfile, args.vmdk))
			else:
				print("qemu-img convert -f raw -O vmdk {} {}".format(self.imgfile, self._yaml['vmdk']))

		if(args.vdi):
			assert('vdi' in self._yaml or isinstance(args.vdi, str))
			if(isinstance(args.vdi, str)):
				print("qemu-img convert -f raw -O vdi {} {}".format(self.imgfile, args.vdi))
			else:
				print("qemu-img convert -f raw -O vdi {} {}".format(self.imgfile, self._yaml['vdi']))


def size_to_sectors(size):
	if(size[-1] == 'M'):
		return int(size[:-1]) << 11;
	elif(size[-1] == 'G'):
		return int(size[:-1]) << 21;
	else:
		raise RuntimeError('invalid size given: {}'.format(size))

parser = argparse.ArgumentParser()
parser.add_argument('file', help='input YAML file')
parser.add_argument('-m', '--modify', type=int)
parser.add_argument('-o', '--output', help='override output file')
parser.add_argument('-b', '--bootloader', help='install bootloader as specified in configuration file', action='store_true')
parser.add_argument('--mount', help='mount the partitions instead of using root-less tools (requires rsync)', action='store_true')
parser.add_argument('--temp-mount-dir', action='store', type=str, default="mnt", const=True, nargs='?', help='temporary folder to use for mounting (default \'mnt\')')
parser.add_argument('--dont-create-mount-dir', action='store_true', help='disable creation and deletion of temporary mount folder')
parser.add_argument('--elevator', action='store', type=str, default=False, const=True, nargs='?', help='tool to use to elevate privileges')
parser.add_argument('--vmdk', action='store', type=str, default=False, const=True, nargs='?', help='build a VMDK image')
parser.add_argument('--vdi', action='store', type=str, default=False, const=True, nargs='?', help='build a VDI image')
args = parser.parse_args()

if args.mount and not args.dont_create_mount_dir:
	print("mkdir -p {}".format(args.temp_mount_dir))

config = Config(yaml.load(open(args.file, 'r'), Loader=yaml.SafeLoader), args)
config.build()

if args.mount and not args.dont_create_mount_dir:
	print("rm -r {}".format(args.temp_mount_dir))

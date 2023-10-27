#!/bin/bash


username='ra1nyy'
hostname='BBR-WAH9'
pass='arch'
sleep=10

clear

echo '>> Russification...'
loadkeys ru
setfont cyr-sun16
echo -e 'KEYMAP=ru\nFONT=cyr-sun16\n' > /etc/vconsole.conf

sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen
sed -i 's/#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/g' /etc/locale.gen
locale-gen

export LANG=ru_RU.UTF-8

echo '--------------------------------------------------'
echo '|          Форматирование разделов               |'
echo '--------------------------------------------------'

mkfs.ext4 /dev/nvme0n1p5

sleep $sleep

echo '--------------------------------------------------'
echo '|             Подключение разделов               |'
echo '--------------------------------------------------'

echo ">> Подключение разделов"
mount /dev/nvme0n1p5 /mnt
mount --mkdir /dev/nvme0n1p1 /boot/efi

sleep $sleep

echo '--------------------------------------------------'
echo '|             Установка Arch Linux               |'
echo '--------------------------------------------------'

echo '>> Установка базовой системы'
pacstrap /mnt base linux linux-firmware
echo '>>Генерация таблицы файловых систем'
genfstab /mnt >> /mnt/etc/fstab

sleep $sleep

echo '>> Установка настройки сети'
pacman -Sy networkmanager --noconfirm
systemctl enable NetworkManager

echo ">> Синхронизация времени"
timedatectl set-ntp true
hwclock --systohc
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
timedatectl status

arch-chroot /mnt sh -c "$(cat chroot)" $username $hostname  $pass

sleep $sleep

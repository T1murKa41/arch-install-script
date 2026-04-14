#!/bin/bash

set -e

sleep=5

clear

echo '>> Русификация консоли...'
loadkeys ru
setfont cyr-sun16
echo -e 'KEYMAP=ru\nFONT=cyr-sun16\n' > /etc/vconsole.conf

sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' /etc/locale.gen
sed -i 's/#ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/g' /etc/locale.gen
locale-gen

export LANG=ru_RU.UTF-8

echo 'Введите ваше дисковое устройство (например /dev/sda или /dev/nvme0n1)'
read disk

echo 'Введите имя пользователя'
read username

echo 'Введите имя хоста (компьютера)'
read hostname

echo 'Введите пароль пользователя'
read -s pass
echo
echo 'Подтвердите пароль'
read -s pass_confirm
echo

if [ "$pass" != "$pass_confirm" ]; then
  echo 'Ошибка: пароли не совпадают!'
  exit 1
fi

# Определяем разделы на основе типа диска (nvme или sata/scsi)
if [[ "$disk" == *"nvme"* ]]; then
  efi_part="${disk}p1"
  root_part="${disk}p5"
else
  efi_part="${disk}1"
  root_part="${disk}5"
fi

echo '--------------------------------------------------'
echo '|          Форматирование разделов               |'
echo '--------------------------------------------------'

mkfs.ext4 "$root_part"

sleep $sleep

echo '--------------------------------------------------'
echo '|             Подключение разделов               |'
echo '--------------------------------------------------'

mount "$root_part" /mnt
mount --mkdir "$efi_part" /mnt/boot/efi

sleep $sleep

echo '--------------------------------------------------'
echo '|             Установка Arch Linux               |'
echo '--------------------------------------------------'

echo '>> Установка базовой системы'
pacstrap /mnt base base-devel linux linux-firmware linux-headers

echo '>> Генерация таблицы файловых систем (по UUID)'
genfstab -U /mnt >> /mnt/etc/fstab

sleep $sleep

echo '>> Синхронизация времени'
timedatectl set-ntp true

echo '>> Копирование chroot-скрипта в /mnt'
cp chroot /mnt/chroot_setup.sh
chmod +x /mnt/chroot_setup.sh

echo '>> Запуск chroot-установки'
arch-chroot /mnt /chroot_setup.sh "$username" "$hostname" "$pass" "$root_part"

echo '>> Очистка временных файлов'
rm /mnt/chroot_setup.sh

echo '--------------------------------------------------'
echo '|       Установка завершена! Перезагрузите       |'
echo '--------------------------------------------------'

sleep $sleep

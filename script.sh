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

echo ''
echo '>> Доступные диски:'
lsblk -d -o NAME,SIZE,MODEL
echo ''

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

echo ''
echo '--------------------------------------------------'
echo '|            Разметка диска                      |'
echo '--------------------------------------------------'

echo ''
echo '>> Запуск cfdisk для разметки диска...'
echo '   Создайте разделы и сохраните таблицу (Write), затем выйдите (Quit).'
echo ''
read -p 'Нажмите Enter чтобы открыть cfdisk...'
cfdisk "$disk"

echo ''
echo '>> Текущие разделы на диске:'
lsblk "$disk"
echo ''

read -p 'Укажите EFI раздел (например /dev/sda1): ' efi_part
read -p 'Укажите корневой раздел (например /dev/sda2): ' root_part
read -p 'Укажите swap раздел (Enter если нет): ' swap_part

echo ''
echo '--------------------------------------------------'
echo '|          Форматирование разделов               |'
echo '--------------------------------------------------'

read -p "Форматировать EFI раздел $efi_part как FAT32? [y/N]: " fmt_efi
if [ "$fmt_efi" = "y" ] || [ "$fmt_efi" = "Y" ]; then
    echo '>> Форматирование EFI раздела (FAT32)...'
    mkfs.fat -F32 "$efi_part"
fi

if [ -n "$swap_part" ]; then
    echo '>> Создание swap...'
    mkswap "$swap_part"
fi

echo '>> Форматирование корневого раздела (ext4)...'
mkfs.ext4 "$root_part"

sleep $sleep

echo '--------------------------------------------------'
echo '|             Подключение разделов               |'
echo '--------------------------------------------------'

mount "$root_part" /mnt
mount --mkdir "$efi_part" /mnt/boot/efi

if [ -n "$swap_part" ]; then
    echo '>> Активация swap...'
    swapon "$swap_part"
fi

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

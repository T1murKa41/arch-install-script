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
echo 'Выберите режим разметки:'
echo '  1) Автоматическая (УДАЛИТ ВСЕ ДАННЫЕ на диске)'
echo '  2) Ручная (укажите уже созданные разделы)'
echo ''
read -p 'Ваш выбор [1/2]: ' partition_mode

swap_part=""

if [ "$partition_mode" = "1" ]; then

    echo ''
    echo "!!! ВНИМАНИЕ: все данные на диске $disk будут УНИЧТОЖЕНЫ !!!"
    read -p 'Введите YES для подтверждения: ' confirm
    if [ "$confirm" != "YES" ]; then
        echo 'Отменено.'
        exit 1
    fi

    echo ''
    read -p 'Размер swap-раздела в ГБ (0 — без swap): ' swap_size

    echo ''
    echo '>> Очистка таблицы разделов...'
    sgdisk --zap-all "$disk"
    sgdisk -o "$disk"

    echo '>> Создание EFI раздела (512 МБ)...'
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System" "$disk"

    if [ "$swap_size" -gt 0 ] 2>/dev/null; then
        echo ">> Создание swap раздела (${swap_size} ГБ)..."
        sgdisk -n 2:0:+${swap_size}G -t 2:8200 -c 2:"Linux swap" "$disk"
        echo '>> Создание корневого раздела (остаток диска)...'
        sgdisk -n 3:0:0 -t 3:8300 -c 3:"Linux filesystem" "$disk"
        swap_num=2
        root_num=3
    else
        echo '>> Создание корневого раздела (остаток диска)...'
        sgdisk -n 2:0:0 -t 2:8300 -c 2:"Linux filesystem" "$disk"
        swap_num=""
        root_num=2
    fi

    # Ждём обновления ядра о новой таблице разделов
    partprobe "$disk" 2>/dev/null || true
    sleep 2

    # Определяем имена разделов
    if [[ "$disk" == *"nvme"* ]]; then
        efi_part="${disk}p1"
        root_part="${disk}p${root_num}"
        [ -n "$swap_num" ] && swap_part="${disk}p${swap_num}"
    else
        efi_part="${disk}1"
        root_part="${disk}${root_num}"
        [ -n "$swap_num" ] && swap_part="${disk}${swap_num}"
    fi

    echo ''
    echo '--------------------------------------------------'
    echo '|          Форматирование разделов               |'
    echo '--------------------------------------------------'

    echo '>> Форматирование EFI раздела (FAT32)...'
    mkfs.fat -F32 "$efi_part"

    if [ -n "$swap_part" ]; then
        echo '>> Создание swap...'
        mkswap "$swap_part"
    fi

    echo '>> Форматирование корневого раздела (ext4)...'
    mkfs.ext4 "$root_part"

else

    echo ''
    echo 'Откройте другой терминал, разметьте диск вручную,'
    echo 'затем вернитесь сюда. Используйте fdisk, gdisk, cfdisk или parted.'
    read -p 'Нажмите Enter когда разметка завершена...'

    echo ''
    echo '>> Текущие разделы:'
    lsblk
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
        mkfs.fat -F32 "$efi_part"
    fi

    if [ -n "$swap_part" ]; then
        echo '>> Создание swap...'
        mkswap "$swap_part"
    fi

    echo '>> Форматирование корневого раздела (ext4)...'
    mkfs.ext4 "$root_part"

fi

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

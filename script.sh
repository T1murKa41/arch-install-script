#!/usr/bin/env bash
#
# Установщик Arch Linux (UEFI). Запускать из live-окружения Arch ISO от root:
#   bash script.sh
# Файл chroot должен лежать рядом со script.sh.

set -Eeuo pipefail
trap 'echo "Ошибка в строке $LINENO: $BASH_COMMAND" >&2' ERR

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG=/tmp/arch-install.log

# ---------------------------------------------------------------- помощники

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BOLD=$'\e[1m'; C_OFF=$'\e[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''; C_OFF=''
fi

info()   { echo "${C_GREEN}>>${C_OFF} $*"; }
warn()   { echo "${C_YELLOW}!!${C_OFF} $*" >&2; }
die()    { echo "${C_RED}Ошибка:${C_OFF} $*" >&2; exit 1; }
header() { echo; echo "${C_BOLD}== $* ==${C_OFF}"; }

# ask VAR "Вопрос" [значение по умолчанию]
ask() {
    local __var=$1 __prompt=$2 __def=${3-} __reply
    if [[ -n $__def ]]; then
        read -r -p "$__prompt [$__def]: " __reply
        __reply=${__reply:-$__def}
    else
        read -r -p "$__prompt: " __reply
    fi
    printf -v "$__var" '%s' "$__reply"
}

# ask_valid VAR "Вопрос" "значение по умолчанию" "regex" "сообщение об ошибке"
ask_valid() {
    local __var=$1 __prompt=$2 __def=$3 __re=$4 __err=$5 __val
    while :; do
        ask __val "$__prompt" "$__def"
        [[ $__val =~ $__re ]] && break
        warn "$__err"
    done
    printf -v "$__var" '%s' "$__val"
}

# ask_block VAR "Вопрос" — запрашивает путь, пока он не станет блочным устройством
ask_block() {
    local __var=$1 __prompt=$2 __val
    while :; do
        ask __val "$__prompt"
        [[ -b $__val ]] && break
        warn "$__val не является блочным устройством"
    done
    printf -v "$__var" '%s' "$__val"
}

# ask_password VAR "Вопрос"
ask_password() {
    local __var=$1 __prompt=$2 __p1 __p2
    while :; do
        read -r -s -p "$__prompt: " __p1; echo
        [[ -n $__p1 ]] || { warn 'Пароль не может быть пустым'; continue; }
        read -r -s -p 'Повторите пароль: ' __p2; echo
        [[ $__p1 == "$__p2" ]] && break
        warn 'Пароли не совпадают, попробуйте ещё раз'
    done
    printf -v "$__var" '%s' "$__p1"
}

# confirm "Вопрос" [y|n] — по умолчанию n
confirm() {
    local def=${2:-n} hint reply
    [[ $def == y ]] && hint='Y/n' || hint='y/N'
    read -r -p "$1 [$hint]: " reply
    case ${reply:-$def} in
        [Yy]|[Yy][Ee][Ss]|Д|д|Да|да) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------- проверки

preflight() {
    header 'Проверка окружения'

    [[ $EUID -eq 0 ]] || die 'скрипт нужно запускать от root'
    [[ -d /sys/firmware/efi/efivars ]] \
        || die 'система загружена не в режиме UEFI (скрипт ставит rEFInd и требует UEFI)'
    [[ -f $SCRIPT_DIR/chroot ]] || die "не найден файл $SCRIPT_DIR/chroot"

    local cmd
    for cmd in lsblk cfdisk blkid mkfs.ext4 mkfs.fat mkswap pacstrap genfstab arch-chroot; do
        command -v "$cmd" >/dev/null || die "не найдена команда $cmd"
    done

    info 'Проверка сети...'
    ping -c 1 -W 3 archlinux.org >/dev/null 2>&1 \
        || die 'нет доступа в интернет (archlinux.org недоступен)'
}

setup_console() {
    loadkeys ru || true
    setfont cyr-sun16 || true
    # Параллельные загрузки ускоряют pacstrap в live-окружении
    sed -i 's/^#\?ParallelDownloads.*/ParallelDownloads = 5/' /etc/pacman.conf
}

detect_ucode() {
    if grep -q GenuineIntel /proc/cpuinfo; then
        ucode=intel
    elif grep -q AuthenticAMD /proc/cpuinfo; then
        ucode=amd
    else
        ucode=none
    fi
}

# ---------------------------------------------------------------- ввод

partition_disk() {
    header 'Разметка диска'

    echo
    lsblk -d -o NAME,SIZE,TYPE,MODEL
    echo
    ask_block disk 'Диск для установки (например /dev/sda или /dev/nvme0n1)'

    if confirm "Открыть cfdisk для разметки $disk?" y; then
        info 'Создайте разделы (EFI ~512M, root, по желанию swap), нажмите Write и Quit.'
        read -r -p 'Нажмите Enter, чтобы открыть cfdisk...'
        cfdisk "$disk"
        partprobe "$disk" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
    fi

    echo
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,MOUNTPOINTS "$disk"
    echo

    while :; do
        ask_block efi_part  'EFI раздел (например /dev/sda1)'
        ask_block root_part 'Корневой раздел (например /dev/sda2)'
        [[ $efi_part != "$root_part" ]] && break
        warn 'EFI и корневой раздел должны быть разными'
    done

    swap_part=''
    while :; do
        ask swap_part 'Swap раздел (Enter — без swap)'
        [[ -z $swap_part ]] && break
        if [[ -b $swap_part && $swap_part != "$efi_part" && $swap_part != "$root_part" ]]; then
            break
        fi
        warn 'укажите существующий блочный раздел, отличный от EFI и root'
    done

    format_efi=no
    if confirm "Форматировать EFI раздел $efi_part в FAT32? (НЕТ — если там уже стоит Windows или другая ОС)" n; then
        format_efi=yes
    fi
}

collect_settings() {
    header 'Настройки системы'

    ask_valid username 'Имя пользователя' '' '^[a-z_][a-z0-9_-]{0,31}$' \
        'допустимы строчные латинские буквы, цифры, "_" и "-"; начинать нужно с буквы'
    ask_valid hostname 'Имя хоста' '' '^[A-Za-z0-9]([A-Za-z0-9-]{0,62})$' \
        'допустимы латинские буквы, цифры и "-"'

    while :; do
        ask timezone 'Часовой пояс' 'Europe/Moscow'
        [[ -f /usr/share/zoneinfo/$timezone ]] && break
        warn "часовой пояс $timezone не найден в /usr/share/zoneinfo"
    done

    ask_password user_pass "Пароль пользователя $username"
    if confirm 'Использовать тот же пароль для root?' y; then
        root_pass=$user_pass
    else
        ask_password root_pass 'Пароль root'
    fi

    install_desktop=no
    install_zsh=no
    confirm 'Установить XFCE4 + SDDM + Firefox?' y && install_desktop=yes
    confirm 'Установить zsh и oh-my-zsh?' y && install_zsh=yes

    detect_ucode
}

show_summary() {
    header 'Проверьте параметры установки'
    cat <<EOF
  Диск:               $disk
  EFI раздел:         $efi_part  (форматировать: $format_efi)
  Корневой раздел:    $root_part  (будет отформатирован в ext4)
  Swap раздел:        ${swap_part:-нет}
  Пользователь:       $username
  Имя хоста:          $hostname
  Часовой пояс:       $timezone
  Микрокод:           $ucode
  XFCE4 + SDDM:       $install_desktop
  zsh + oh-my-zsh:    $install_zsh
EOF
    echo
    warn "Все данные на $root_part будут УНИЧТОЖЕНЫ."
    local answer
    read -r -p 'Для продолжения введите YES: ' answer
    [[ $answer == YES ]] || die 'установка отменена'
}

# ---------------------------------------------------------------- установка

format_and_mount() {
    header 'Форматирование и монтирование'

    if [[ $format_efi == yes ]]; then
        info "Форматирование $efi_part (FAT32)"
        mkfs.fat -F32 "$efi_part"
    fi
    if [[ -n $swap_part ]]; then
        info "Создание swap на $swap_part"
        mkswap "$swap_part"
    fi

    info "Форматирование $root_part (ext4)"
    mkfs.ext4 -q "$root_part"

    mount "$root_part" /mnt
    mount --mkdir "$efi_part" /mnt/boot/efi
    if [[ -n $swap_part ]]; then
        swapon "$swap_part"
    fi
}

install_base() {
    header 'Установка базовой системы'

    info 'Синхронизация времени'
    timedatectl set-ntp true

    local pkgs=(
        base base-devel linux linux-headers linux-firmware
        networkmanager sudo vim nano
        refind gdisk efibootmgr
    )
    if [[ $ucode != none ]]; then
        pkgs+=("$ucode-ucode")
    fi

    pacstrap -K /mnt "${pkgs[@]}" 2>&1 | tee -a "$LOG"

    info 'Генерация fstab (по UUID)'
    genfstab -U /mnt >> /mnt/etc/fstab
}

configure_system() {
    header 'Настройка системы в chroot'

    install -m 700 "$SCRIPT_DIR/chroot" /mnt/root/chroot_setup.sh

    local root_uuid
    root_uuid=$(blkid -s UUID -o value "$root_part")
    [[ -n $root_uuid ]] || die "не удалось определить UUID раздела $root_part"

    # Пароли не передаются аргументами (их видно в ps) — только через stdin
    arch-chroot /mnt /root/chroot_setup.sh \
        "$username" "$hostname" "$timezone" "$root_uuid" "$ucode" \
        "$install_desktop" "$install_zsh" 2>&1 | tee -a "$LOG"

    info 'Установка паролей'
    printf '%s:%s\n%s:%s\n' "$username" "$user_pass" root "$root_pass" \
        | arch-chroot /mnt chpasswd

    rm -f /mnt/root/chroot_setup.sh
}

finish() {
    header 'Установка завершена'
    info "Журнал установки: $LOG"

    if confirm 'Размонтировать разделы и перезагрузиться?' y; then
        if [[ -n $swap_part ]]; then
            swapoff "$swap_part"
        fi
        umount -R /mnt
        reboot
    fi
}

main() {
    clear
    setup_console
    preflight
    partition_disk
    collect_settings
    show_summary
    format_and_mount
    install_base
    configure_system
    finish
}

main "$@"

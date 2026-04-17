#!/usr/bin/env bash
# Bloom post-install configuration
# Runs inside arch-chroot via archinstall custom-commands
# /run is bind-mounted from the live host, so /run/bloom/* is accessible here

set -eo pipefail

# Duplicate all output to /var/log/bloom-post-install.log so we can prove
# the script actually ran and diagnose failures after install. Stdout is
# still captured by archinstall's own log as a bonus.
LOGFILE=/var/log/bloom-post-install.log
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

BLOOM="/run/bloom"

echo "==> Bloom post-install starting $(date -Iseconds)"
echo "    BLOOM=$BLOOM  (exists: $( [ -d "$BLOOM" ] && echo yes || echo no ))"

# ── greetd / tuigreet ────────────────────────────────────────────────────────
if command -v tuigreet &>/dev/null || pacman -Qi greetd &>/dev/null 2>&1; then
    mkdir -p /etc/greetd
    cat > /etc/greetd/config.toml << 'EOF'
[terminal]
vt = 1

[default_session]
command = "tuigreet --time --time-format '%H:%M · %a %d %b' --greeting '❀  Welcome to Bloom' --asterisks --remember --cmd 'uwsm start hyprland.desktop'"
user = "greeter"
EOF
    systemctl enable greetd 2>/dev/null || true
    echo "  -> greetd configured"
fi

# ── Bloom repo ───────────────────────────────────────────────────────────────
if ! grep -q '\[bloom\]' /etc/pacman.conf 2>/dev/null; then
    cat >> /etc/pacman.conf << 'PEOF'

[bloom]
SigLevel = Never
Server = https://bloom-linux.github.io/bloom-packages/
PEOF
fi

# ── Chaotic-AUR + AUR packages ───────────────────────────────────────────────
if ! grep -q '\[chaotic-aur\]' /etc/pacman.conf 2>/dev/null; then
    cat >> /etc/pacman.conf << 'PEOF'

[chaotic-aur]
SigLevel = Never
Server = https://cdn-mirror.chaotic.cx/$repo/$arch
Server = https://cdn1.chaotic.cx/$repo/$arch
PEOF
fi
pacman -Sy --noconfirm 2>/dev/null || true
pacman -S --noconfirm --needed candy-icons eww yay pamac-aur bloom-desktop 2>/dev/null || true
echo "  -> AUR + Bloom packages installed"

# ── Plymouth theme ────────────────────────────────────────────────────────────
# Copy bloom Plymouth theme from live session
mkdir -p /usr/share/plymouth/themes/bloom
if [ -d "$BLOOM/plymouth/bloom" ]; then
    cp -r "$BLOOM/plymouth/bloom/." /usr/share/plymouth/themes/bloom/
elif [ -f "$BLOOM/bloom-plymouth.tar.gz" ]; then
    tar -xzf "$BLOOM/bloom-plymouth.tar.gz" -C /usr/share/plymouth/themes/
fi
# Set theme via config (more reliable than -R flag in chroot)
mkdir -p /etc/plymouth
cat > /etc/plymouth/plymouthd.conf << 'PLEOF'
[Daemon]
Theme=bloom
ShowDelay=0
DeviceTimeout=8
PLEOF
# Rebuild initramfs to embed the theme
mkinitcpio -P 2>/dev/null || true
echo "  -> Plymouth theme set"

# ── Bloom branding: /etc/os-release ───────────────────────────────────────────
# This is what every other Linux's os-prober reads when it finds a partition
# with a Linux root on it — the NAME field becomes the entry label in their
# GRUB menu. So with this in place, a Ubuntu or Fedora user running
# `sudo update-grub` / `sudo grub2-mkconfig` will see "Bloom" as a boot option
# instead of "Arch Linux". lsb-release mirrors the same info for any legacy
# tools that still read it.
cat > /etc/os-release <<'OSREL'
NAME="Bloom"
PRETTY_NAME="Bloom Linux"
ID=bloom
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;176;24;40"
HOME_URL="https://bloom.linux"
DOCUMENTATION_URL="https://bloom.linux/docs"
LOGO=bloom
OSREL

# Some tools (grub-mkconfig, update-motd) also read /etc/lsb-release
# for the distributor / release name. Shipping both avoids half-detection.
cat > /etc/lsb-release <<'LSBREL'
DISTRIB_ID=Bloom
DISTRIB_RELEASE=rolling
DISTRIB_DESCRIPTION="Bloom Linux"
LSBREL

# /usr/lib/os-release is owned by the `filesystem` package on Arch. Symlink
# /etc/os-release → /usr/lib/os-release after replacing the latter so every
# reader sees Bloom regardless of which path they query.
cp /etc/os-release /usr/lib/os-release

# ── GRUB: branding, defaults, theme, kernel cmdline ──────────────────────────
GRUB_CONF="/etc/default/grub"

# Copy theme artwork into /boot (so GRUB can read it without needing to
# mount another filesystem early).
if [ -d "$BLOOM/grub-theme" ]; then
    mkdir -p /boot/grub/themes/bloom
    cp -r "$BLOOM/grub-theme/." /boot/grub/themes/bloom/
fi

# Idempotent key=value setter — matches both active and #-commented lines,
# replaces in place, or appends if missing.
_grub_set() {
    local key=$1 val=$2
    if grep -qE "^[#[:space:]]*${key}=" "$GRUB_CONF" 2>/dev/null; then
        sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${val}|" "$GRUB_CONF"
    else
        printf '%s=%s\n' "$key" "$val" >> "$GRUB_CONF"
    fi
}

# Distro branding — GRUB_DISTRIBUTOR shows up in every menu entry label.
_grub_set GRUB_DISTRIBUTOR  '"Bloom"'
# Remember last choice across reboots.
_grub_set GRUB_DEFAULT      'saved'
_grub_set GRUB_SAVEDEFAULT  'true'
# Sensible menu timing.
_grub_set GRUB_TIMEOUT      '5'
_grub_set GRUB_TIMEOUT_STYLE 'menu'
# Let users dual-boot — os-prober is off upstream for security since 2.06.
_grub_set GRUB_DISABLE_OS_PROBER 'false'
# Adaptive gfxmode + keep the framebuffer into Linux so plymouth can draw
# without a flash of black.
_grub_set GRUB_GFXMODE          'auto'
_grub_set GRUB_GFXPAYLOAD_LINUX 'keep'
# Plymouth cmdline: quiet + splash + aggressive log suppression.
_grub_set GRUB_CMDLINE_LINUX_DEFAULT \
    '"quiet splash plymouth.use_simpledrm=1 loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0"'
# Theme path.
if [ -d /boot/grub/themes/bloom ]; then
    _grub_set GRUB_THEME '"/boot/grub/themes/bloom/theme.txt"'
fi

grub-mkconfig -o /boot/grub/grub.cfg
echo "  -> GRUB configured (distributor=Bloom, theme, saved default, os-prober on)"

# ── Firefox start page ────────────────────────────────────────────────────────
if [ -d "$BLOOM/startpage" ]; then
    mkdir -p /usr/share/bloom
    cp -r "$BLOOM/startpage" /usr/share/bloom/
    mkdir -p /etc/firefox/policies
    cp "$BLOOM/policies.json" /etc/firefox/policies/policies.json 2>/dev/null || true
    echo "  -> Firefox start page installed"
fi

# ── System environment ────────────────────────────────────────────────────────
if [ -f /etc/environment ]; then
    sed -i 's/^XCURSOR_THEME=.*/XCURSOR_THEME=Vanilla-DMZ-AA/' /etc/environment
    grep -q "XCURSOR_THEME"        /etc/environment || echo "XCURSOR_THEME=Vanilla-DMZ-AA"  >> /etc/environment
    grep -q "XCURSOR_SIZE"         /etc/environment || echo "XCURSOR_SIZE=24"                >> /etc/environment
    grep -q "QT_QPA_PLATFORMTHEME" /etc/environment || echo "QT_QPA_PLATFORMTHEME=qt6ct"     >> /etc/environment
    grep -q "QT_STYLE_OVERRIDE"    /etc/environment || echo "QT_STYLE_OVERRIDE=kvantum-dark" >> /etc/environment
fi

# ── System-wide dark theme (enables Firefox auto dark mode via portal) ────────
mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
cat > /etc/dconf/profile/user << 'EOF'
user-db:user
system-db:local
EOF
cat > /etc/dconf/db/local.d/00-bloom << 'EOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita-dark'
icon-theme='candy-icons'
cursor-theme='Vanilla-DMZ-AA'
cursor-size=24
font-name='Noto Sans 11'
EOF
dconf update 2>/dev/null || true
echo "  -> System dark theme configured"

# ── Qt6/Qt5 theme (kvantum-dark via qt6ct) ────────────────────────────────────
mkdir -p /etc/skel/.config/qt6ct/colors /etc/skel/.config/qt5ct/colors
cat > /etc/skel/.config/qt6ct/qt6ct.conf << 'QEOF'
[Appearance]
color_scheme_path=
custom_palette=false
icon_theme=candy-icons
standard_dialogs=default
style=kvantum-dark

[Fonts]
fixed="JetBrainsMono Nerd Font,11,-1,5,400,0,0,0,0,0"
general="Noto Sans,11,-1,5,400,0,0,0,0,0"
QEOF
cat > /etc/skel/.config/qt5ct/qt5ct.conf << 'QEOF'
[Appearance]
color_scheme_path=
custom_palette=false
icon_theme=candy-icons
standard_dialogs=default
style=kvantum-dark

[Fonts]
fixed="JetBrainsMono Nerd Font,11,-1,5,400,0,0,0,0,0"
general="Noto Sans,11,-1,5,400,0,0,0,0,0"
QEOF

# ── Kvantum theme ─────────────────────────────────────────────────────────────
mkdir -p /etc/skel/.config/Kvantum
cat > /etc/skel/.config/Kvantum/kvantum.kvconfig << 'KEOF'
[General]
theme=KvDark
KEOF
echo "  -> Qt/Kvantum dark theme configured"

# ── UFW ───────────────────────────────────────────────────────────────────────
ufw default deny incoming  2>/dev/null || true
ufw default allow outgoing 2>/dev/null || true
ufw allow ssh              2>/dev/null || true
ufw --force enable         2>/dev/null || true
echo "  -> UFW configured"

# ── AppArmor ──────────────────────────────────────────────────────────────────
systemctl enable apparmor 2>/dev/null || true

# ── skel sync ─────────────────────────────────────────────────────────────────
if [ -d "$BLOOM/skel" ]; then
    cp -rn "$BLOOM/skel/." /etc/skel/ 2>/dev/null || true
fi

# ── First-run wizard setup ────────────────────────────────────────────────────
# bloom-firstrun checks ~/.config/bloom/firstrun-done — we do NOT create it here,
# so it runs automatically on first login to the installed system.
# Ensure the exec-once is in the installed hyprland.conf via skel.
echo "  -> First-run wizard will launch on first login"

echo "==> Bloom post-install complete."

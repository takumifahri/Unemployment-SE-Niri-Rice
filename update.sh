#!/usr/bin/env bash
# FR Navy v17: riwayat clipboard + emoji, indikator hotspot di waybar, repo Git; v16.2: hotspot lewat hostapd (jalan dengan iwd); v16: hotspot dari Wi-Fi laptop (fr-hotspot); v15: batas pengisian baterai (fr-charge); v14: pilih area QR + pembaca zxing; Wi-Fi via QR; alat (screenshot, rekam, warna, scratchpad, kalender); mode daya + profil; optimasi performa; palet tema; lockscreen baru + wallpaper lock terpisah + monitor sistem; control center lengkap + popup wifi/volume/brightness, sysinfo waybar, launcher ber-grup
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"

# paket wajib + opsional
need=()
for p in "magick:imagemagick" "playerctl:playerctl" "grim:grim" "slurp:slurp" "satty:satty" "hyprpicker:hyprpicker" "wl-copy:wl-clipboard" "cliphist:cliphist" "wtype:wtype" "curl:curl" "ZXingReader:zxing-cpp" "zbarcam:zbar" "qrencode:qrencode" "dnsmasq:dnsmasq" "hostapd:hostapd" "nft:nftables" "iw:iw" "nmcli:networkmanager" "powerprofilesctl:power-profiles-daemon" "pactl:libpulse" \
         "brightnessctl:brightnessctl" "btop:btop" "wlsunset:wlsunset" "bluetoothctl:bluez-utils"; do
  command -v "${p%%:*}" >/dev/null || need+=("${p#*:}")
done
if ((${#need[@]})); then
  read -rp "Install ${need[*]}? [y/N] " a
  [[ $a =~ ^[Yy]$ ]] && sudo pacman -S --needed "${need[@]}"
fi
if command -v powerprofilesctl >/dev/null && ! systemctl is-active -q power-profiles-daemon; then
  for c in tlp auto-cpufreq tuned; do
    systemctl is-active -q "$c" 2>/dev/null && { echo "!! $c aktif — bentrok dengan power-profiles-daemon, lewati."; break; }
  done
  systemctl is-active -q tlp auto-cpufreq tuned 2>/dev/null || sudo systemctl enable --now power-profiles-daemon
fi

# file
mkdir -p "$HOME/.local/bin" "$CFG/radial-launcher" "$CFG/fr-control" "$CFG/fr-sysmon" "$CFG/fr-theme" "$CFG/fr-wifiqr"

# laptop baru: pulihkan config pribadi dari personal/ (hasil ./snapshot.sh), tanpa menimpa yang sudah ada
if [[ -d "$HERE/personal" ]]; then
  while IFS= read -r -d '' f; do
    rel=${f#"$HERE/personal/"}
    if [[ $rel == face.png ]]; then dst="$HOME/.face"; else dst="$CFG/$rel"; fi
    # niri membuat config default saat pertama jalan: itu boleh diganti (dibackup dulu)
    if [[ $rel == niri/config.kdl && -f $dst ]] && ! grep -q 'fr-binds.kdl\|fr-power.kdl' "$dst"; then
      mv "$dst" "$dst.bak-default"; echo "  config niri default dibackup ke config.kdl.bak-default"
    fi
    if [[ ! -e $dst ]]; then
      mkdir -p "$(dirname "$dst")"; cp "$f" "$dst"; echo "  dipulihkan: $rel"
    fi
  done < <(find "$HERE/personal" -type f -print0)
fi

# tema: file yang akan disalin memakai palet navy, jadi tema aktif dipasang ulang di akhir
cp "$HERE/theme/themes.json" "$CFG/fr-theme/"
saved_theme=$(cat "$CFG/fr-theme/current" 2>/dev/null || echo navy)
echo navy > "$CFG/fr-theme/current"
install -m755 "$HERE/bin/fr-toggle" "$HERE/bin/fr-sysmon-sample" "$HERE/bin/fr-theme" "$HERE/bin/fr-thumbs" "$HERE/bin/fr-power" "$HERE/bin/fr-avatar" "$HERE/bin/fr-media" "$HERE/bin/fr-lockstyle" "$HERE/bin/fr-shot" "$HERE/bin/fr-pick" "$HERE/bin/fr-scratch" "$HERE/bin/fr-rec" "$HERE/bin/fr-weather" "$HERE/bin/fr-wifiqr" "$HERE/bin/fr-charge" "$HERE/bin/fr-hotspot" "$HERE/bin/fr-hotspot-bar" "$HERE/bin/fr-clip" "$HERE/bin/fr-emoji" "$HOME/.local/bin/"
cp "$HERE/waybar/config.jsonc" "$HERE/waybar/style.css" "$CFG/waybar/"
cp "$HERE/fuzzel/fuzzel.ini" "$CFG/fuzzel/"
# lockscreen: file gaya selalu diperbarui; hyprlock.conf cuma menunjuk gaya pilihanmu
cp "$HERE/hypr/hyprlock-editorial.conf" "$HERE/hypr/hyprlock-center.conf" "$CFG/hypr/"
LOCK="$CFG/hypr/hyprlock.conf"
if [[ -f $LOCK ]] && grep -q '^source = \./hyprlock-' "$LOCK"; then
  :   # sudah memakai fr-lockstyle
elif [[ -f $LOCK ]]; then
  # config lama: tebak gayanya; kalau buatan sendiri, simpan sebagai gaya "custom"
  if grep -q 'hyprlock "editorial"' "$LOCK"; then style=editorial
  elif grep -qE 'gaya tengah|semua di tengah|FR Navy — hyprlock$' "$LOCK"; then style=center
  else cp "$LOCK" "$CFG/hypr/hyprlock-custom.conf"; style=custom; fi
  cp "$LOCK" "$LOCK.bak-lockstyle"
  "$HOME/.local/bin/fr-lockstyle" "$style" >/dev/null
  echo "  lockscreen: gaya '$style' dipertahankan, sekarang lewat fr-lockstyle (backup: hyprlock.conf.bak-lockstyle)"
else
  "$HOME/.local/bin/fr-lockstyle" editorial >/dev/null
fi
cp "$HERE/radial-launcher/shell.qml" "$CFG/radial-launcher/"
cp "$HERE/control-center/shell.qml"  "$CFG/fr-control/"
cp "$HERE/sysmon/shell.qml"          "$CFG/fr-sysmon/"
cp "$HERE/wifiqr/shell.qml"          "$CFG/fr-wifiqr/"

if [[ ! -e "$CFG/hypr/wallpaper.png" ]]; then
  first=$(ls "$HOME"/Pictures/Wallpaper/*.{png,jpg,jpeg,webp} 2>/dev/null | head -1 || true)
  [[ -n $first ]] && ln -sf "$first" "$CFG/hypr/wallpaper.png"
fi
# lockscreen: kalau belum ada, ikut wallpaper desktop
[[ -e "$CFG/hypr/lock.png" ]] || ln -sf "$CFG/hypr/wallpaper.png" "$CFG/hypr/lock.png"

# mode daya: service otomatis (dinyalakan dari panel → "Otomatis ikut charger")
mkdir -p "$CFG/systemd/user"
cp "$HERE/systemd/fr-power-auto.service" "$HERE/systemd/fr-charge.service" "$CFG/systemd/user/"
systemctl --user daemon-reload 2>/dev/null || true

# emoji + pencatat clipboard (langsung jalan, tanpa perlu login ulang)
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/fr-emoji"
cp "$HERE/emoji/emoji.txt" "${XDG_DATA_HOME:-$HOME/.local/share}/fr-emoji/"
if command -v cliphist >/dev/null && [[ -n ${WAYLAND_DISPLAY:-} ]]; then
  (nohup "$HOME/.local/bin/fr-clip" watch >/dev/null 2>&1 &)
fi

# hotspot: helper root kecil (cuma bisa buat/hapus antarmuka "frap0") + izin sudo tanpa password khusus helper itu
HS=/usr/local/bin/fr-hotspot-iface
SUD=/etc/sudoers.d/fr-hotspot
if ! cmp -s "$HERE/bin/fr-hotspot-iface" "$HS" || ! sudo -n -l "$HS" >/dev/null 2>&1; then
  echo "Memasang helper hotspot (butuh sudo)…"
  tmp=$(mktemp)
  echo "$USER ALL=(root) NOPASSWD: $HS" > "$tmp"
  if sudo install -o root -g root -m755 "$HERE/bin/fr-hotspot-iface" "$HS" && sudo visudo -cf "$tmp" >/dev/null &&
     sudo install -o root -g root -m440 "$tmp" "$SUD"; then
    echo "  helper hotspot terpasang"
  else
    echo "  gagal memasang helper (hotspot sambil tetap Wi-Fi tidak akan jalan)"
  fi
  rm -f "$tmp"
fi
# versi awal hotspot memakai profil NetworkManager; sekarang hostapd langsung
nmcli connection delete fr-hotspot >/dev/null 2>&1 || true

# batas pengisian baterai: butuh sysfs charge_control_end_threshold + izin tulis lewat udev
for t in /sys/class/power_supply/BAT*/charge_control_end_threshold; do
  [[ -e $t ]] || continue
  grp=$(id -gn)
  rule="/etc/udev/rules.d/99-fr-charge.rules"
  want="ACTION==\"add|change\", SUBSYSTEM==\"power_supply\", KERNEL==\"BAT*\", RUN+=\"/bin/sh -c 'chgrp $grp /sys%p/charge_control_end_threshold; chmod g+w /sys%p/charge_control_end_threshold'\""
  if [[ ! -w $t ]] || ! grep -qsF "chgrp $grp" "$rule"; then
    echo "Batas pengisian didukung. Memasang aturan udev (butuh sudo)…"
    echo "$want" | sudo tee "$rule" >/dev/null && sudo udevadm control --reload && sudo udevadm trigger -s power_supply -c change || echo "  gagal memasang aturan udev (batas pengisian dilewati)"
  fi
  systemctl --user enable fr-charge.service 2>/dev/null || true
  break
done

# mode daya: niri membaca efek Irit dari fr-power.kdl (include opsional, di paling akhir)
NIRI="$CFG/niri/config.kdl"
if [[ -f $NIRI ]] && ! grep -q 'fr-power.kdl' "$NIRI"; then
  cp "$NIRI" "$NIRI.bak-fr-power"
  printf '\n// fr-power: efek mode Irit (animasi & shadow). Harus di paling bawah.\ninclude optional=true "./fr-power.kdl"\n' >> "$NIRI"
  echo "  config niri: ditambah include fr-power.kdl (backup: config.kdl.bak-fr-power)"
fi
[[ -f "$CFG/niri/fr-power.kdl" ]] || echo "// Dibuat otomatis oleh fr-power." > "$CFG/niri/fr-power.kdl"

# alat: keybind screenshot/rekam/warna/scratchpad + aturan jendela (Zoom, satty)
cp "$HERE/niri/fr-binds.kdl" "$CFG/niri/"
if [[ -f $NIRI ]] && ! grep -q 'fr-binds.kdl' "$NIRI"; then
  [[ -f "$NIRI.bak-fr-binds" ]] || cp "$NIRI" "$NIRI.bak-fr-binds"
  printf '\n// fr-binds: keybind & aturan jendela FR (screenshot, rekam, warna, scratchpad, Zoom)\ninclude optional=true "./fr-binds.kdl"\n' >> "$NIRI"
  echo "  config niri: ditambah include fr-binds.kdl"
fi
# "Buka dengan → Sambung Wi-Fi dari QR" di file manager
mkdir -p "$HOME/.local/share/applications"
cp "$HERE/applications/fr-wifiqr.desktop" "$HOME/.local/share/applications/"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$HOME/.local/share/applications" || true

mkdir -p "$CFG/satty"
cp "$HERE/satty/config.toml" "$CFG/satty/"
command -v gpu-screen-recorder >/dev/null || command -v wf-recorder >/dev/null || \
  echo "  catatan: untuk rekam layar, install 'gpu-screen-recorder' dari AUR (yay -S gpu-screen-recorder)"

# profil: avatar inisial kalau belum punya foto
[[ -s "$HOME/.face" ]] || "$HOME/.local/bin/fr-avatar" default >/dev/null 2>&1 || true

# media di lockscreen: siapkan gambar kosong untuk saat tidak ada yang diputar
"$HOME/.local/bin/fr-media" art >/dev/null 2>&1 || true

# thumbnail wallpaper untuk panel, dibuat di latar belakang
(nohup "$HOME/.local/bin/fr-thumbs" >/dev/null 2>&1 &)

[[ $saved_theme != navy ]] && "$HOME/.local/bin/fr-theme" "$saved_theme" || true

pkill waybar || true
(waybar >/dev/null 2>&1 & disown)
echo "Beres. Coba: ~/.local/bin/fr-toggle fr-control"

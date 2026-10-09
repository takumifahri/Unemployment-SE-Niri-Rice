#!/usr/bin/env bash
# snapshot.sh — salin config PRIBADI yang hidup di laptop ke folder personal/ di repo ini,
# supaya ikut ter-commit. Kebalikannya: ./update.sh memulihkan personal/ di laptop baru
# (hanya file yang belum ada; file yang sudah ada tidak pernah ditimpa).
#
#   ./snapshot.sh               niri config, tema aktif, nama tampilan, kota cuaca, gaya lockscreen, batas charge
#   ./snapshot.sh --with-photo  + foto profil (~/.face). Jangan dipakai kalau repo-nya publik.
#
# Tidak pernah disalin: password hotspot, password Wi-Fi, riwayat clipboard.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
P="$HERE/personal"
mkdir -p "$P"

copy() {   # copy <sumber> <tujuan relatif di personal/>
  [[ -f $1 ]] || return 0
  mkdir -p "$P/$(dirname "$2")"
  cp "$1" "$P/$2"
  echo "  + $2"
}
echo "Menyalin ke personal/:"
copy "$CFG/niri/config.kdl"               niri/config.kdl
copy "$CFG/fr-theme/current"              fr-theme/current
copy "$CFG/fr-profile/name"               fr-profile/name
copy "$CFG/fr-profile/city"               fr-profile/city
copy "$CFG/fr-profile/charge-limit"       fr-profile/charge-limit
copy "$CFG/hypr/hyprlock.conf"            hypr/hyprlock.conf
[[ ${1:-} == --with-photo ]] && copy "$HOME/.face" face.png

# file niri hasil generate otomatis jangan ikut (dibuat ulang oleh update.sh / fr-power)
echo
echo "Selesai. Lanjutkan di folder repo:"
echo "  git status"
echo "  git add -A && git commit -m 'snapshot' && git push"

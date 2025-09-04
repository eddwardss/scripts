#!/bin/bash
#
# pkg-info.sh — package information in Debian/Ubuntu
#
# Copyright (C) 2025 Твоё Имя
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail
#set -x

SCRIPT_NAME=$(basename "$0")

print_usage() {
  cat <<EOF
Использование: $SCRIPT_NAME [флаг] [параметр]

Флаги:
  --group <секция>            Показать пакеты в секции
  --group-list <секция>       Только имена пакетов секции
  --groups                    Список всех секций
  --search <пакет>            Поиск пакетов по имени
  --search-pretty <пакет>     Поиск с fuzzy-сравнением
  --files <пакет>             Показать файлы пакета (поиск online)
  --rdepends <пакет>          Обратные зависимости пакета
  --orphans                   Поиск сиротских пакетов
  --orphans-full              Поиск сиротских пакетов оставшихся с предыдущих установок
  --data <N|YYYYMMDD>         Последние установки или по дате
  <пакет>                     Информация о пакете (apt show)

Примеры:
  $SCRIPT_NAME --group xfce
  $SCRIPT_NAME --group-list editors
  $SCRIPT_NAME --data 10
  $SCRIPT_NAME --data 20250829
  $SCRIPT_NAME thunar
EOF
}

print_block() {
  local start_date="$1"
  local cmdline="$2"
  local install_line="$3"

  echo "Дата установки: $start_date"
  echo "Команда: $cmdline"
  echo "Пакеты:"

  # Разбор строки пакетов на отдельные элементы с учетом вложенных скобок
  awk -v line="$install_line" '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s);
      return s;
    }
    function split_pkgs(s, arr,   i, c, level, start, pos) {
      level = 0
      start = 1
      c = 0
      for (pos = 1; pos <= length(s); pos++) {
        ch = substr(s, pos, 1)
        if (ch == "(") level++
        else if (ch == ")") level--
        else if (ch == "," && level == 0) {
          c++
          arr[c] = trim(substr(s, start, pos - start))
          start = pos + 1
        }
      }
      c++
      arr[c] = trim(substr(s, start))
      return c
    }
    BEGIN {
      n = split_pkgs(line, pkgs)
      for (i = 1; i <= n; i++) {
        print "  - " pkgs[i]
      }
    }
  '
  echo "------------------------------------------"
}

# ---------- FUNCTIONS ----------


show_package_files_online_or_local() {
  local pkg="$1"

  if dpkg -s "$pkg" &>/dev/null; then
    echo "📂 Файлы пакета '$pkg' (установленного):"
    dpkg -L "$pkg"
  else
    echo "⚠️  Пакет '$pkg' не установлен. Попытка получить список файлов с packages.debian.org..."

    local distro
    distro=$(lsb_release -sc 2>/dev/null || echo "stable")

    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

    local url="https://packages.debian.org/${distro}/${arch}/${pkg}/filelist"

    if curl --head --silent --fail "$url" >/dev/null; then
      echo "📂 Файлы пакета '$pkg' (из репозитория Debian):"
      curl -s "$url" | sed -n '/<pre>/,/<\/pre>/p' | sed 's/<[^>]*>//g'
    else
      echo "⚠️  Не удалось получить список файлов с сайта Debian."
    fi
  fi
}

extract_packages_by_group() {
  local group="$1"
  local with_desc="$2"
  local group_lc=$(echo "$group" | tr '[:upper:]' '[:lower:]')

  awk -v grp="$group" -v grplc="$group_lc" -v with_desc="$with_desc" '
  BEGIN { RS=""; FS="\n" }
  {
    pkg=""; desc=""; section=""; tags=""; homepage=""
    for (i=1; i<=NF; i++) {
      if ($i ~ /^Package: /) pkg = substr($i, 10)
      else if ($i ~ /^Section: /) section = substr($i, 10)
      else if ($i ~ /^Description: /) desc = substr($i, 14)
      else if ($i ~ /^Homepage: /) homepage = substr($i, 11)
      else if ($i ~ /^Tag: /) {
        tags = substr($i, 6)
        for (j=i+1; j<=NF; j++) {
          if ($j ~ /^[ \t]/ || $j ~ /^[^:]+::/) tags = tags " " $j
          else break
        }
      }
    }

    # Lowercase fields for case-insensitive search
    desc_lc = tolower(desc)
    homepage_lc = tolower(homepage)

    if (section == grp || tags ~ ("suite::" grp) || desc_lc ~ grplc || homepage_lc ~ grplc) {
      if (with_desc == "yes")
        print pkg ": " desc
      else
        print pkg
    }
  }
  ' /var/lib/apt/lists/*Packages 2>/dev/null
}

show_package_info_status() {
  local pkg="$1"
  local status=$(dpkg -s "$pkg" 2>/dev/null | grep '^Status:')
  if [[ "$status" == "Status: install ok installed" ]]; then
    echo "$status"
  else
    echo "Status: not installed"
  fi
}

show_package_info() {
  local pkg="$1"
  if apt-cache show "$pkg" &>/dev/null; then
    apt show "$pkg"
  else
    echo "❌ Пакет '$pkg' не найден"
  fi
}

# Пакеты по паттерну (grep по имени)
group_like() {
  local pattern="$1"
  apt-cache dumpavail | awk -v pat="$pattern" '
    $1=="Package:" {pkg=$2}
    $1=="Section:" {
      if ($0 ~ pat) print pkg
    }
  '
}

show_all_groups() {
  apt-cache dumpavail | grep '^Section:' | cut -d' ' -f2 | sort -u
}

search_packages() {
  local name="$1"
  apt-cache search "$name"
}

show_package_files_online() {
  local pkg="$1"
  local arch=$(dpkg --print-architecture)
  local codename=$(lsb_release -sc)
  local url="https://packages.debian.org/$codename/$arch/$pkg/filelist"

  echo "🌐 Получение списка файлов с $url ..."
  curl -s "$url" | grep -A100 "<ul>" | grep '<li>' | sed -E 's/<[^>]+>//g' || echo "❌ Не удалось получить список"
}

show_rdepends() {
  local pkg="$1"
  apt-cache rdepends "$pkg"
}


find_orphans_lite() {
  echo "🔍 Поиск сиротских пакетов..."

  if command -v deborphan >/dev/null 2>&1; then
    echo "⚙️  Используется deborphan:"
    deborphan
    return
  fi

  if command -v debfoster >/dev/null 2>&1; then
    echo "⚠️ deborphan не найден. Пытаемся debfoster..."
    orphans_debfoster
    return
  fi

  # Ни deborphan, ни debfoster — предлагаем установить и выполняем резервный поиск
  echo "⚠️ Не найдены deborphan или debfoster."
  echo "Установите одну из утилит для точного поиска сирот:"
  echo "  sudo apt install deborphan"
  echo "  sudo apt install debfoster"
  echo ""
  echo "Выполняется резервный поиск (менее точный):"
  
  # Менее точный способ: ищем пакеты, не являющиеся зависимостями других
#  comm -23 \
#    <(apt-mark showauto | sort) \
#    <(apt-mark showmanual | sort) |
#  while read -r pkg; do
#    if ! apt-cache rdepends --installed "$pkg" | grep -qE '^\s{2,}\w'; then
#      echo "$pkg"
#    fi
#  done
  apt autoremove --dry-run
}


find_orphans_full() {
  set +e +u +o pipefail
  echo "🔍 Поиск сирот (auto‑пакеты, не требуемые другими)"
  echo "   с учётом Depends, Recommends, Suggests..."
  echo "   Это займёт много времени..."
   
  echo -e "\n1. Получаем ручные и авто‑пакеты…"
  mapfile -t manual < <(apt-mark showmanual)
  mapfile -t auto < <(apt-mark showauto)
  echo "   Manual: ${#manual[@]}, Auto: ${#auto[@]}"
   
  echo -e "\n2. Сбор зависимостей (Depends, Recommends, Suggests)…"
  mapfile -t deps < <(
    dpkg-query -W -f='${Package}\t${Depends}\t${Recommends}\t${Suggests}\n' | \
    while IFS=$'\t' read -r pkg depends recs suggs; do
      for field in "$depends" "$recs" "$suggs"; do
        IFS=',' read -ra arr <<< "$field"
        for dep in "${arr[@]}"; do
          dep=$(echo "$dep" | sed -E 's/\s*\(.*\)//g' | awk -F'|' '{print $1}' | xargs) #'
          [[ -n "$dep" ]] && echo -e "$pkg\t$dep"
        done
      done
    done
  )
  total=${#deps[@]}
  echo "   Всего зависимостей: $total"
   
  echo -e "\n3. Строим reachable‑пакеты от manual…"
  reachable=("${manual[@]}")
  changed=1
  while [[ $changed -eq 1 ]]; do
    changed=0
    count=0
    for depline in "${deps[@]}"; do
      ((count++))
      percent=$((count * 100 / total))
      printf "\r🚀 Обход зависимостей... %3d%% (%d/%d)" "$percent" "$count" "$total"
   
      pkg="${depline%%$'\t'*}"
      dep="${depline#*$'\t'}"
   
      if printf '%s\n' "${reachable[@]}" | grep -qx "$pkg"; then
        if ! printf '%s\n' "${reachable[@]}" | grep -qx "$dep"; then
          reachable+=("$dep")
          changed=1
        fi
      fi
    done
  done
  echo -e "\n✅ Обход зависимостей завершён."
  echo "   Reachable пакетов: ${#reachable[@]}"
   
  echo -e "\n4. 🧹 Поиск безопасных orphan-пакетов (auto, но недостижимых)…"
   
  system_patterns=(
    '^linux-.*'
    '^systemd.*'
    '^initramfs.*'
    '^grub.*'
    '^libc6.*'
    '^libstdc.*'
    '^gcc.*'
    '^dpkg.*'
    '^apt.*'
    '^perl.*'
    '^bash$'
    '^dash$'
    '^coreutils$'
    '^debconf$'
    '^login$'
    '^passwd$'
    '^sudo$'
    '^util-linux$'
    '^hostname$'
    '^netbase$'
    '^base-files$'
    '^base-passwd$'
  )
   
  is_system_package() {
    local pkg="$1"
    for pattern in "${system_patterns[@]}"; do
      if [[ $pkg =~ $pattern ]]; then
        return 0
      fi
    done
    return 1
  }
   
  declare -a orphan_safe
  declare -A holds
  count=0
  for a in "${auto[@]}"; do
    if ! printf '%s\n' "${reachable[@]}" | grep -qx "$a"; then
      if ! is_system_package "$a"; then
        if apt-mark showhold | grep -xq "$a"; then
          holds["$a"]=1
          echo "$a [hold]"
        else
          echo "$a"
        fi
        orphan_safe+=("$a")
        ((count++))
      fi
    fi
  done
   
  echo -e "\n✅ Найдено безопасных сирот: $count"
   
  echo -e "\n5. 🔎 Проверка orphan-пакетов на наличие других версий (возможные остатки после обновлений)…"

  # Получаем список установленных пакетов с версиями
  mapfile -t installed_versions < <(dpkg-query -W -f='${Package}\t${Version}\n')

  declare -A version_map
  for line in "${installed_versions[@]}"; do
    pkg="${line%%$'\t'*}"
    ver="${line#*$'\t'}"
    version_map["$pkg"]="$ver"
  done

  declare -a version_duplicates=()

  # Функция для получения базового имени пакета без архитектуры и суффиксов
  get_base_name() {
    local pkg="$1"
    # Убираем архитектуру (после двоеточия)
    pkg="${pkg%%:*}"
    # Убираем суффикс после последнего дефиса, если это служебный суффикс
    if [[ "$pkg" =~ ^(.+)-([0-9]+|dev|doc|dbg|common|tools|utils)$ ]]; then
      echo "${BASH_REMATCH[1]}"
    else
      echo "$pkg"
    fi
  }

  for orphan in "${orphan_safe[@]}"; do
    orphan_ver="${version_map[$orphan]:-}"
    [[ -z "$orphan_ver" ]] && continue

    if is_system_package "$orphan"; then
      continue
    fi

    orphan_base=$(get_base_name "$orphan")

    for pkg in "${!version_map[@]}"; do
      [[ "$pkg" == "$orphan" ]] && continue

      if is_system_package "$pkg"; then
        continue
      fi

      pkg_ver="${version_map[$pkg]}"
      pkg_base=$(get_base_name "$pkg")

      if [[ "$pkg_base" == "$orphan_base" && "$pkg_ver" != "$orphan_ver" ]]; then
        echo "⚠️  $orphan ($orphan_ver) → $pkg ($pkg_ver)"
        version_duplicates+=("$orphan → $pkg")
      fi
    done
  done

  if [[ ${#version_duplicates[@]} -eq 0 ]]; then
    echo "✅ Устаревшие версии не найдены."
  else
    echo -e "\n📦 Возможные устаревшие версии:"
    printf ' - %s\n' "${version_duplicates[@]}"
  fi

  echo "[DEBUG] Блок 5 успешно завершён"

  set -euo pipefail
}


# Показ последних установок (N по умолчанию 5)
show_recent_installs() {
  local count="${1:-5}"

  echo "🕒 Последние $count установок пакетов:"
  echo "------------------------------------------"

  local logs=$(ls -t /var/log/apt/history.log* 2>/dev/null || true)
  if [[ -z "$logs" ]]; then
    echo "Нет журналов apt history для анализа"
    return
  fi

  # Извлекаем блоки установки
  zgrep -h -E '^(Start-Date|Commandline|Install:)' $logs | \
    awk '
      /^Start-Date:/ {
        if (block) print "";
        block=1;
        print "📅 " $0;
      }
      /^Commandline:/ { print "💻 " $0; }
      /^Install:/ { print "📦 " $0; }
    ' | awk -v RS= -v ORS="\n\n" '1' | head -n $(($count * 8))
}

show_installs_full_by_date() {
  local target_date="$1"
  echo "📅 Подробный список установок за дату: $target_date"
  echo "------------------------------------------"

  local in_block=0
  local current_date=""
  local install_buffer=""
  local print_block=0

  zgrep -h -E '^(Start-Date|Commandline|Install):' /var/log/apt/history.log* | while IFS= read -r line; do
    if [[ "$line" =~ ^Start-Date:\ ([0-9]{4})-([0-9]{2})-([0-9]{2}) ]]; then
      # Новый блок — печатаем предыдущий, если был
      if [[ $print_block -eq 1 && -n "$install_buffer" ]]; then
        echo "Install: $install_buffer"
        echo
      fi

      # Сравниваем даты
      current_date="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
      if [[ "$current_date" == "$target_date" ]]; then
        echo "$line"
        print_block=1
      else
        print_block=0
      fi

      install_buffer=""
      continue
    fi

    if [[ $print_block -eq 1 ]]; then
      if [[ "$line" =~ ^Commandline: ]]; then
        echo "$line"
      elif [[ "$line" =~ ^Install:\ (.*) ]]; then
        # Убираем начальный префикс и накапливаем
        local installs="${BASH_REMATCH[1]}"
        install_buffer+="${install_buffer:+, }$installs"
      fi
    fi
  done

  # Печатаем последний блок, если попал
  if [[ $print_block -eq 1 && -n "$install_buffer" ]]; then
    echo "Install: $install_buffer"
  fi
}

show_installed_names_by_date() {
  local target_date="$1"
  echo "📦 Список имён пакетов, установленных за дату: $target_date"
  echo "------------------------------------------"

  zgrep -h -E '^(Start-Date|Install:)' /var/log/apt/history.log* | awk -v date="$target_date" '
    BEGIN { capture = 0 }
    /^Start-Date:/ {
      match($0, /Start-Date: ([0-9]{4}-[0-9]{2}-[0-9]{2})/, m)
      capture = (m[1] == date)
    }
    /^Install:/ && capture {
      line = $0
      sub(/^Install: /, "", line)

      n = split(line, entries, /, ?/)
      for (i = 1; i <= n; i++) {
        pkg = entries[i]
        gsub(/^ +| +$/, "", pkg)  # trim
        match(pkg, /^([^:]+):/, m)
        if (m[1] != "")
          print m[1]
      }
    }
  ' | sort -u
}

show_installs_by_date() {
  local raw_date="$1"
  local formatted_date

  if [[ "$raw_date" =~ ^[0-9]{8}$ ]]; then
    formatted_date="$(date -d "${raw_date:0:4}-${raw_date:4:2}-${raw_date:6:2}" +%Y-%m-%d 2>/dev/null)"
  elif [[ "$raw_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    formatted_date="$raw_date"
  else
    echo "❌ Неверный формат даты: $raw_date"
    echo "   Используй YYYY-MM-DD или YYYYMMDD"
    return 1
  fi

  echo "📅 Краткий список установленных пакетов за дату: $formatted_date"
  echo "------------------------------------------"

  local logs=$(ls -t /var/log/apt/history.log* 2>/dev/null || true)
  if [[ -z "$logs" ]]; then
    echo "Нет журналов apt history для анализа"
    return
  fi

  zgrep -h -E '^(Start-Date|Install:)' $logs | \
  awk -v date="$formatted_date" '
    function trim(s) {
      gsub(/^[ \t]+|[ \t]+$/, "", s)
      return s
    }
    # Функция для разбивки строки install по запятым вне скобок
    function split_pkgs(s, arr,   i, c, level, start, pos) {
      level = 0
      start = 1
      c = 0
      for (pos = 1; pos <= length(s); pos++) {
        ch = substr(s, pos, 1)
        if (ch == "(") level++
        else if (ch == ")") level--
        else if (ch == "," && level == 0) {
          c++
          arr[c] = trim(substr(s, start, pos - start))
          start = pos + 1
        }
      }
      c++
      arr[c] = trim(substr(s, start))
      return c
    }

    /^Start-Date:/ {
      current_date = $2
      capture = (current_date == date) ? 1 : 0
    }
    capture && /^Install:/ {
      sub(/^Install: /, "")
      n = split_pkgs($0, pkgs)
      for (i = 1; i <= n; i++) {
        print pkgs[i]
      }
    }
  ' | sort -u
}



# ---------- MAIN ----------

CMD="${1:-}"
ARG="${2:-}"


case "$CMD" in
  --help|-h|"")
    print_usage
    ;;
  --groups)
    show_all_groups
    ;;
  --group)
    if [ -z "$ARG" ]; then show_usage; fi
    echo "📦 Пакеты в секции или suite '$ARG' с описаниями:"
    extract_packages_by_group "$ARG" yes
    exit 0
    ;;
  --group-list)
    if [ -z "$ARG" ]; then show_usage; fi
    echo "📦 Пакеты в секции или suite '$ARG':"
    extract_packages_by_group "$ARG" no |sort
    exit 0
    ;;
  --files)
    if [ -z "$ARG" ]; then
      echo "⚠️  Укажи имя пакета."
      exit 1
    fi
    show_package_files_online_or_local "$ARG"
    ;;
  --rdepends)
    show_rdepends "$ARG"
    ;;
  --orphans)
    find_orphans_lite
    ;;
  --orphans-full)
    find_orphans_full
    ;;
  --data)
    if [[ "$ARG" =~ ^[0-9]+$ ]]; then
        show_recent_installs "$ARG"
    else
        show_installs_by_date "$ARG"
    fi
    ;;
  --data-full)
    DATE_PARAM="$2"
    # Нормализуй дату если нужно (например 20240806 → 2024-08-06)
    if [[ "$DATE_PARAM" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})$ ]]; then
      DATE_PARAM="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
    fi
    show_installs_full_by_date "$DATE_PARAM"
    ;;
  --data-list)
    shift
    show_installed_names_by_date "$1"
    ;;
  *)
    if [[ -n "$CMD" ]]; then
      show_package_info_status "$CMD"
      show_package_info "$CMD"
    else
      print_usage
    fi
    ;;
esac

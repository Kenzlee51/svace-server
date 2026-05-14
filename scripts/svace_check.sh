#!/usr/bin/env bash
# =============================================================================
# svace_check.sh
# Проверяет обновление Svace по смене токена в редиректе.
# При изменении — скачивает и регистрирует новый дистрибутив на сервере.
#
# Запуск вручную:   ./svace_check.sh
# Только проверка:  ./svace_check.sh --check-only
# Cron (пн 9:00):   0 9 * * 1 /path/to/svace_check.sh >> /path/to/svace_check.log 2>&1
# =============================================================================

# --- Настройки ---
SOURCE_URL="https://download.ispras.ru/svace"
SVACE_VERSIONS_DIR="/home/user/svace-versions"
SVACE_SERVER_DIR="/home/user/svace-server-5"
SVACE_EXECUTE_PATH="/home/user/svace-versions/svace-5.0.251220-x64-linux/bin/svace"

# --- Служебные пути (рядом со скриптом, не менять) ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN_FILE="$SCRIPT_DIR/.svace_token"
WEBDAV_BASE="https://nextcloud.ispras.ru/public.php/webdav"
CHECK_ONLY="${1:-}"

# --- Логирование ---
STEP=0
LOG() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
STEP_OK()  { LOG "  [ШАГ $STEP ОК] $*"; }
STEP_FAIL() {
    LOG "  [ШАГ $STEP ОШИБКА] $*"
    LOG "  Успешно завершены шаги: ${COMPLETED_STEPS[*]:-нет}"
    LOG "  Прерывание."
    exit 1
}
declare -a COMPLETED_STEPS=()
next_step() {
    STEP=$((STEP + 1))
    LOG "--- Шаг $STEP: $* ---"
}
complete_step() {
    COMPLETED_STEPS+=("$STEP")
    STEP_OK "$*"
}

# URL-encode (для имён с пробелами)
urlencode() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$1"
}

# =============================================================================
# ШАГ 1: Получаем актуальный токен из редиректа
# =============================================================================
next_step "Получение токена из редиректа"

final_url=$(curl -s -o /dev/null -w '%{url_effective}' -L "$SOURCE_URL")
current_token=$(echo "$final_url" | grep -oP '(?<=/s/)[^/?]+')

if [[ -z "$current_token" ]]; then
    STEP_FAIL "Не удалось извлечь токен из '$final_url'"
fi
LOG "Текущий токен: $current_token"
complete_step "Токен получен: $current_token"

# =============================================================================
# ШАГ 2: Сравниваем с сохранённым токеном
# =============================================================================
next_step "Сравнение токенов"

saved_token=""
if [[ -f "$TOKEN_FILE" ]]; then
    saved_token=$(grep '^TOKEN=' "$TOKEN_FILE" | cut -d= -f2)
fi

if [[ "$current_token" == "$saved_token" ]]; then
    LOG "Версия не изменилась. Ничего делать не нужно."
    exit 0
fi

if [[ -z "$saved_token" ]]; then
    LOG "Первый запуск — файл состояния будет создан."
else
    LOG "Токен изменился: $saved_token → $current_token"
fi
complete_step "Обнаружено обновление"

# =============================================================================
# ШАГ 3: Получаем список файлов из папки Svace/ и определяем LATEST_SVACE
# =============================================================================
next_step "Получение списка файлов через WebDAV"

if [[ "$CHECK_ONLY" == "--check-only" ]]; then
    LOG "Режим проверки — дальнейшие шаги пропущены."
    exit 0
fi

encoded_path=$(urlencode "Svace")
xml=$(curl -s --max-time 30 \
    -u "${current_token}:" \
    -X PROPFIND \
    -H "Depth: 1" \
    -H "Content-Type: application/xml" \
    --data '<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:displayname/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>' \
    "$WEBDAV_BASE/${encoded_path}/")

if [[ -z "$xml" ]]; then
    STEP_FAIL "Пустой ответ от WebDAV для пути /Svace/"
fi

# Ищем файл вида svace-*-x64-linux.tar.bz2
LATEST_SVACE=$(echo "$xml" | grep -oP '(?<=<d:displayname>)[^<]+' \
    | grep -P 'svace-.*-x64-linux\.tar\.bz2$' | head -1)

if [[ -z "$LATEST_SVACE" ]]; then
    STEP_FAIL "Не найден файл svace-*-x64-linux.tar.bz2 в папке Svace/"
fi

# Извлекаем версию: svace-5.0.260414-x64-linux.tar.bz2 → 5.0.260414
LATEST_VERSION=$(echo "$LATEST_SVACE" | grep -oP '(?<=svace-)[\d.]+')
LATEST_SVACE_DIR="${LATEST_SVACE%.tar.bz2}"

if [[ -z "$LATEST_VERSION" ]]; then
    STEP_FAIL "Не удалось извлечь версию из имени файла '$LATEST_SVACE'"
fi

LOG "Найден дистрибутив: $LATEST_SVACE"
LOG "Папка после распаковки: $LATEST_SVACE_DIR"
LOG "Версия:             $LATEST_VERSION"
if [[ -z "$LATEST_SVACE_DIR" ]]; then
    STEP_FAIL "Не удалось определить имя папки из '$LATEST_SVACE'"
fi

complete_step "Определены LATEST_SVACE=$LATEST_SVACE, LATEST_SVACE_DIR=$LATEST_SVACE_DIR, LATEST_VERSION=$LATEST_VERSION"

# =============================================================================
# ШАГ 4: Сохраняем состояние в .svace_token
# =============================================================================
next_step "Сохранение состояния в $TOKEN_FILE"

cat > "$TOKEN_FILE" << TOKENEOF
TOKEN=$current_token
LATEST_SVACE=$LATEST_SVACE
LATEST_SVACE_DIR=$LATEST_SVACE_DIR
LATEST_VERSION=$LATEST_VERSION
TOKENEOF

if [[ $? -ne 0 ]]; then
    STEP_FAIL "Не удалось записать файл $TOKEN_FILE"
fi
complete_step "Состояние сохранено"

# =============================================================================
# ШАГ 5: Скачиваем архив (если ещё не скачан)
# =============================================================================
next_step "Скачивание $LATEST_SVACE"

mkdir -p "$SVACE_VERSIONS_DIR"
ARCHIVE_PATH="$SVACE_VERSIONS_DIR/$LATEST_SVACE"

if [[ -f "$ARCHIVE_PATH" ]]; then
    LOG "Архив уже существует: $ARCHIVE_PATH — пропускаем скачивание."
else
    encoded_file=$(urlencode "$LATEST_SVACE")
    curl -# --max-time 7200 \
        -u "${current_token}:" \
        "$WEBDAV_BASE/Svace/${encoded_file}" \
        -o "$ARCHIVE_PATH"

    if [[ $? -ne 0 || ! -f "$ARCHIVE_PATH" ]]; then
        STEP_FAIL "Ошибка при скачивании $LATEST_SVACE"
    fi
fi
complete_step "Архив готов: $ARCHIVE_PATH"

# =============================================================================
# ШАГ 6: Распаковываем (если папка ещё не существует)
# =============================================================================
next_step "Распаковка архива"

existing_dir="$SVACE_VERSIONS_DIR/$LATEST_SVACE_DIR"

if [[ -d "$existing_dir" ]]; then
    LOG "Папка уже существует: $existing_dir — пропускаем распаковку."
else
    tar -xjf "$ARCHIVE_PATH" -C "$SVACE_VERSIONS_DIR"
    if [[ $? -ne 0 ]]; then
        STEP_FAIL "Ошибка при распаковке $ARCHIVE_PATH"
    fi
    if [[ ! -d "$existing_dir" ]]; then
        STEP_FAIL "После распаковки папка $existing_dir не найдена"
    fi
fi
complete_step "Распаковано в: $existing_dir"

# =============================================================================
# ШАГ 7: Регистрируем дистрибутив на сервере
# =============================================================================
next_step "Регистрация дистрибутива (remote-add-distro)"

cd "$SVACE_SERVER_DIR" || STEP_FAIL "Не удалось перейти в $SVACE_SERVER_DIR"

add_output=$("$SVACE_EXECUTE_PATH" server admin remote-add-distro \
    --name "$LATEST_VERSION" \
    --version "$LATEST_VERSION" \
    --path "$existing_dir" 2>&1)
add_exit=$?

LOG "Вывод remote-add-distro: $add_output"

if [[ $add_exit -ne 0 ]]; then
    STEP_FAIL "remote-add-distro завершился с кодом $add_exit: $add_output"
fi
complete_step "Дистрибутив зарегистрирован"

# =============================================================================
# ШАГ 8: Проверка — наличие бинаря svace в распакованной папке
# =============================================================================
next_step "Проверка наличия $existing_dir/bin/svace"

if [[ ! -x "$existing_dir/bin/svace" ]]; then
    STEP_FAIL "Исполняемый файл $existing_dir/bin/svace не найден или не исполняемый"
fi
complete_step "Бинарь найден: $existing_dir/bin/svace"

# =============================================================================
# ШАГ 9: Проверка — версия появилась в remote-show
# =============================================================================
next_step "Проверка наличия $LATEST_VERSION в remote-show"

show_output=$(cd "$SVACE_SERVER_DIR" && "$SVACE_EXECUTE_PATH" server admin remote-show 2>&1)
show_exit=$?

LOG "Вывод remote-show: $show_output"

if [[ $show_exit -ne 0 ]]; then
    STEP_FAIL "remote-show завершился с кодом $show_exit: $show_output"
fi

if ! echo "$show_output" | grep -qF "$LATEST_VERSION"; then
    STEP_FAIL "$LATEST_VERSION не найден в выводе remote-show"
fi
complete_step "$LATEST_VERSION присутствует в remote-show"

# =============================================================================
# ШАГ 10: Удаляем архив
# =============================================================================
next_step "Удаление архива $ARCHIVE_PATH"

rm -f "$ARCHIVE_PATH"
if [[ $? -ne 0 ]]; then
    STEP_FAIL "Не удалось удалить архив $ARCHIVE_PATH"
fi
complete_step "Архив удалён"

# =============================================================================
LOG "✅ Все шаги завершены успешно. Установлена версия: $LATEST_VERSION"

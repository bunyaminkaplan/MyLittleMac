#!/bin/bash
set -e

# Run Script Build Phase: Helper ve LaunchDaemon Zorunlu Kopyalama ve İmzalama Betiği
# Xcode 14+ Dependency Bypass (alwaysOutOfDate) ile her derlemede zorunlu çalışır.
# Hard-Fail Mekanizması: Kopyalama veya codesign adımı başarısız olursa exit 1 ile derleme durur.

BUILT_PRODUCTS_DIR="${BUILT_PRODUCTS_DIR:-$TARGET_BUILD_DIR}"
BUILT_PRODUCTS_DIR="${BUILT_PRODUCTS_DIR:-$1}"
CONTENTS_FOLDER_PATH="${CONTENTS_FOLDER_PATH:-Contents}"
PROJECT_DIR="${PROJECT_DIR:-${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}}"

if [ -z "$BUILT_PRODUCTS_DIR" ]; then
    echo "⚠️ BUILT_PRODUCTS_DIR belirtilmedi. Derleme ortamında çalıştırınız."
    exit 1
fi

DAEMON_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchDaemons"
mkdir -p "${DAEMON_DIR}" || exit 1

PLIST_PATH="${PROJECT_DIR}/Helper/bunyamin.my-little-mac.helper.plist"

if [ ! -f "${PLIST_PATH}" ]; then
    echo "error: Plist kaynakta yok: ${PLIST_PATH}"
    exit 1
fi

cp "${PLIST_PATH}" "${DAEMON_DIR}/" || { echo "error: Plist kopyalama basarisiz"; exit 1; }

MACOS_DIR="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/MacOS"
mkdir -p "${MACOS_DIR}" || exit 1

HELPER_PATH="${PROJECT_DIR}/Helper/bunyamin.my-little-mac.helper"

if [ ! -f "${HELPER_PATH}" ]; then
    echo "error: Helper binary kaynakta yok: ${HELPER_PATH}"
    exit 1
fi

cp "${HELPER_PATH}" "${MACOS_DIR}/" || { echo "error: Helper kopyalama basarisiz"; exit 1; }

# Helper ikilisini ana uygulamanın sertifikası ve Runtime bayrağı ile imzala (Hard-Fail)
TARGET_HELPER="$MACOS_DIR/bunyamin.my-little-mac.helper"

if [ -n "$EXPANDED_CODE_SIGN_IDENTITY" ]; then
    echo "✍️ [Build Script] Helper codesign ($EXPANDED_CODE_SIGN_IDENTITY)..."
    codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$TARGET_HELPER" || { echo "error: Helper codesign basarisiz: $EXPANDED_CODE_SIGN_IDENTITY"; exit 1; }
elif [ -n "$CODE_SIGN_IDENTITY" ]; then
    echo "✍️ [Build Script] Helper codesign ($CODE_SIGN_IDENTITY)..."
    codesign --force --options runtime --sign "$CODE_SIGN_IDENTITY" "$TARGET_HELPER" || { echo "error: Helper codesign basarisiz: $CODE_SIGN_IDENTITY"; exit 1; }
else
    echo "✍️ [Build Script] Helper codesign (ad-hoc / development)..."
    codesign --force --options runtime --sign - "$TARGET_HELPER" || { echo "error: Helper codesign ad-hoc basarisiz"; exit 1; }
fi

echo "✅ [Build Script] Helper ve LaunchDaemon başarıyla paketlendi ve imzalandı."

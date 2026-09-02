# shellcheck shell=bash
# AUR Maintainer original: Shadichy <shadichy@blisslabs.org>
# Adaptado para KernelSU-Next (KSU-Next) — ver notas TODO abajo

_pkg=kernelsu-next
pkgname=${_pkg}-dkms
pkgver=0.3261.g03e52117
_ver=$pkgver
pkgrel=1
_branch=waydroid
pkgdesc="KernelSU-Next: an advanced kernel based root solution for Android. DKMS module for Container-based solutions such as Waydroid."
arch=('any')
# Fork con la rama 'waydroid' ya portada a KernelSU-Next
url="https://github.com/Polaricito/KernelSU-Next-Waydroid"
_upstream="https://github.com/KernelSU-Next/KernelSU-Next.git"
license=('GPL-2.0-only')
depends=('modloader' 'dkms')
makedepends=('git')
options=('!strip' '!emptydirs')

# Using custom download agent to shallow clone the repo
cat <<'EOF' >DLAGENTS
#!/bin/sh

PWD=$(pwd)

ORIGIN=${1#shallowclone+}
ORG_URL=${ORIGIN%%'?'*}
ORG_ARGS=${ORIGIN#*'?'}

DEST=${2}
REAL_DEST=${DEST%.part}

### Parse url parameters

arg_parser() {
  local args=$1
  shift

  IFS='&'
  set -- ${args}
  unset IFS

  BRANCH=
  COMMIT=
  TAG=
  RECURSE_SUBMODULES=
  DEPTH=1

  while [ $# -gt 0 ]; do
    case $1 in
      branch=*) BRANCH=${1#branch=} ;;
      commit=*) COMMIT=${1#commit=} ;;
      tag=*) TAG=${1#tag=} ;;
      recurse=true) RECURSE_SUBMODULES=1 ;;
      depth=*) DEPTH=${1#depth=} ;;
      *) : ;;
    esac
    shift
  done

  export BRANCH COMMIT TAG RECURSE_SUBMODULES DEPTH
}

arg_parser "${ORG_ARGS}"

update_src() {
  git fetch \
    --depth 1 \
    ${RECURSE_SUBMODULES:+'--recurse-submodules'} \
    origin "${COMMIT:-${BRANCH:-${TAG}}}"
}

### Verify if destination already exists and is a valid git repository with the correct remote URL

verify_dest() {
  local dest=$1 current_url
  [ -d "${dest}/.git" ] || return
  echo "Source dest exists, updating..."

  cd "${dest}"
  git remote set-url origin "${ORG_URL}"
  
  { # Abort any in-progress tasks
    git merge --abort ||
      git rebase --abort ||
      git cherry-pick --abort || :
  } 2>/dev/null

  # Update the existing shallow clone
  update_src
  git reset --hard FETCH_HEAD
  cd "${PWD}"

  ln -s "../${dest}" "../src/${dest}"
  echo ${dest}
  exit 0
}

verify_dest "${DEST}"
verify_dest "${REAL_DEST}"

### If not, perform a fresh shallow clone

rm -rf "${DEST}"
mkdir -p "${DEST}"

cd "${DEST}"
git init --quiet
git remote add origin "${ORG_URL}"

update_src
git reset --hard FETCH_HEAD

cd "${PWD}"

ln -s "../${REAL_DEST}" "../src/${REAL_DEST}"
echo ${REAL_DEST}
EOF
chmod +x DLAGENTS
export DLAGENTS="shallowclone::$(realpath "./DLAGENTS") %u %o"

source=(
  "${_pkg}::git+${url}#branch=${_branch}"
  'Makefile'
  'dkms.conf'
  '00-kernelsu.conf'
  'load-kernelsu.in'
)

sha256sums=(
  'SKIP'
  '2fcfe32b430eaef04dfe406ff89bec9580cf499d387d730b933f46195c68f28d'
  '3eaeaf5a2a5442204ae0cad3c4c25855a90e4e683da56579cc7eb2bada42ccb9'
  '05feaafbbac794a68c7eeea8c0a4c5616fc9f6ef7e4b7540baf3f5d43fad5fb0'
  'f01d10fbcfba1b83134746ccfdc7ef4ceb61fa43593b94f039eac3469637429c'
)

pkgver() {
  cd "$srcdir/$_pkg"

  # KernelSU-Next no versiona con tags semver "vX.Y.Z" como tiann/KernelSU
  # (usa códigos de build tipo "12851"/"32925"), así que aquí ya NO tomamos
  # prestados los tags de _upstream como hacía el PKGBUILD original.
  # Solo desenchamos el shallow clone para tener historial completo y
  # dejamos que git describe use lo que tu fork/rama traiga.
  {
    git fetch --unshallow origin "$_branch" || :
  } >/dev/null 2>&1

  local _described
  _described=$(git describe --long --tags 2>/dev/null | sed 's#v##;s#-RC#.rc#;s#-#+#g')

  if [ -n "$_described" ]; then
    echo "$_described"
  else
    # Fallback si tu rama no trae tags anotados: 0.<count>.g<hash-corto>
    echo "0.$(git rev-list --count HEAD).g$(git rev-parse --short HEAD)"
  fi
}

package() {
  local dest="$pkgdir/usr/src/${_pkg}-${pkgver}"
  mkdir -p "$dest"

  cd "$srcdir"
  cp -rpt "$dest" "${_pkg}/kernel/."
  cp -rpt "$dest" "${_pkg}/uapi/."

  cd "$_pkg"

  local _major _count _realver _tag
  _major=${pkgver%%.*}
  _count=$(git rev-list --count HEAD 2>/dev/null)
  _realver=$((_major * 10000 + _count))
  _tag=$(git describe --tags --abbrev=0 2>/dev/null)
  [ -n "$_tag" ] || _tag="v$_count"

  local buildfile=kernel/Kbuild
  if [ ! -f "$buildfile" ]; then
    buildfile=kernel/Makefile
  fi


  cd "$srcdir"

  sed "s|@PKGVER@|${pkgver}|g;\
    s|@KSU_GIT_VERSION@|${_count}|g;\
    s|@KSU_GIT_TAG@|${_tag}|g;" "$(readlink -f dkms.conf)" > "$dest/dkms.conf"

  install -Dm644 "$(readlink -f Makefile)" "$dest/Makefile"

  # Install module config
  mkdir -p "$pkgdir/etc/modprobe.d"
  install -Dm644 "$(readlink -f 00-kernelsu.conf)" "$pkgdir/etc/modprobe.d/"

  # Install load script
  mkdir -p "$pkgdir/usr/bin"
  install -Dm755 "$(readlink -f load-kernelsu.in)" "$pkgdir/usr/bin/load-kernelsu"
}

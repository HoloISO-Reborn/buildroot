#!/bin/bash

# SCRIPT USAGE:
# sudo build.sh
# --flavor <flavor_manifest_name>         (required) Specify which preset to use from presets/ folder
# --snapshot-ver <snapshot_version>       (required) Specify snapshot version string, usually date or custom string
# --workdir <working_directory>           (required) Specify working directory for building
# --output-dir <output_directory>         (optional) Specify output directory for final images,
# --add-release                           (optional) Makes release metadata, forces output to be named "holoiso-images"
# --rclone-path
# --rclone-root
# --donotcompress                         (optional) Skip compression of final image, mainly for testing purposes, cannot create release with this flag

SCRIPT=$(realpath "$0")
SCRIPTPATH=$(dirname "$SCRIPT")

if [ $EUID -ne 0 ]; then
	echo "$(basename $0) must be ran as superuser or sudo"
	exit 1
fi

while [[ $# -gt 0 ]]
do
key="$1"
case $key in
	--flavor)
	BUILD_FLAVOR_MANIFEST="${SCRIPTPATH}/presets/$2.sh"
	BUILD_FLAVOR_MANIFEST_ID="$2"
	POSTCOPY_DIR="$2"
	if [[ "${BUILD_FLAVOR_MANIFEST_ID}" =~ "dev" ]]; then
		BUILD_FLAVOR_MANIFEST_ID=$(echo $2 | cut -d '-' -f 1)
		BRANCH_OVERRIDES=$(echo $2 | cut -d '-' -f 2)
	fi
	shift
	shift
	;;
	--snapshot-ver)
	SNAPSHOTVERSION="$2"
	shift
	shift
	;;
	--workdir)
	WORKDIR="$2/buildwork"
	shift
	shift
	;;
	--output-dir)
	if [[ -z "$2" ]]; then
		OUTPUT=${WORKDIR}
	else
		OUTPUT="$2"
		if [[ -n "${BRANCH_OVERRIDES}" ]]; then
			OUTPUT="$2/${BRANCH_OVERRIDES}"
		fi
	fi
	shift
	shift
	;;
    --add-release)
	IS_HOME_BUILD=true
	if [[ ! "${OUTPUT}" =~ "holoiso-images" ]]; then
		echo "Specific output directories should be preceeded with holoiso-images for release images."
		exit 255
	fi
	shift
	shift
	;;
    --rclone-path)
	RC_PATH="$2"
	shift
	shift
	;;
	--rclone-root)
	if [[ -n "${RC_PATH}" ]]; then
		RC_ROOT="$2"
	else
		echo "rclone root can be used only with --rclone-path"
		exit 255
	fi
	shift
	shift
	;;
    --donotcompress)
	NO_COMPRESS="1"
	if [[ "${IS_HOME_BUILD}" == "true" ]]; then
		echo "Decompressed images are not supported in shipping builds"
		exit 127
	fi
	shift
	shift
	;;
	*)    # unknown option
    echo "Unknown option: $1"
    exit 1
    ;;
esac
done

# Check if everything is set.
if [[ -z "${BUILD_FLAVOR_MANIFEST}" ]]; then
	echo "Build flavor was not set. Aborting."
	exit 0
fi
if [[ -z "${SNAPSHOTVERSION}" ]]; then
	echo "Snapshot directory was not set. Aborting."
	exit 0
fi
if [[ -z "${WORKDIR}" ]]; then
	echo "Workdir was not set. Aborting."
	exit 0
fi

source $BUILD_FLAVOR_MANIFEST
PACCFG=${SCRIPTPATH}/pacman-build-${BUILD_FLAVOR_MANIFEST_ID}.conf
PACCFG_HWSUPPORT=${SCRIPTPATH}/pacman-hwsupport-${BUILD_FLAVOR_MANIFEST_ID}.conf

pacstrap_retry() {
	local cfg="$1"
	local root="$2"
	shift 2

	local log
	log="$(mktemp)"

	for attempt in 1 2 3; do
		echo "pacstrap attempt $attempt..."

		if pacstrap -C "$cfg" "$root" "$@" > >(tee "$log") 2>&1; then
			rm -f "$log"
			return 0
		fi

		echo "pacstrap failed, removing only corrupted cached packages..."

		grep -oE '/[^ ]+\.pkg\.tar\.(zst|xz)' "$log" | sort -u | while read -r pkg; do
			echo "Removing bad cached package: $pkg"
			rm -f "$pkg" "$pkg.sig"
		done

		rm -f /var/cache/pacman/pkg/*.part
	done

	rm -f "$log"
	return 1
}

ROOT_WORKDIR=${WORKDIR}/rootfs_mnt
echo "Preparing to create deployment image..."
# Pre-build cleanup
umount -l ${ROOT_WORKDIR}
rm -rf ${WORKDIR}/*.img*
rm -rf ${WORKDIR}/*.img
rm -rf ${WORKDIR}/work.img

# Start building here
mkdir -p ${WORKDIR}
mkdir -p ${OUTPUT}
mkdir -p ${ROOT_WORKDIR}
if ! fallocate -l 10000M "${WORKDIR}/work.img"; then
    echo "fallocate failed, using dd instead..."
    dd if=/dev/zero of="${WORKDIR}/work.img" bs=1M count=10000 status=progress
fi
mkfs.btrfs -f "${WORKDIR}/work.img"
mkdir -p ${WORKDIR}/rootfs_mnt
mount -t btrfs -o loop,compress=zstd:1,noatime,nodiratime \
    "${WORKDIR}/work.img" "${ROOT_WORKDIR}"
btrfs subvolume create "${ROOT_WORKDIR}/@root"
ROOTFS="${ROOT_WORKDIR}/@root"

echo "(1/6) Bootstrapping main filesystem"
# Start by bootstrapping essentials
mkdir -p ${ROOTFS}/${OS_FS_PREFIX}_root/rootfs
mkdir -p ${ROOTFS}/var/cache/pacman/pkg
mount --bind /var/cache/pacman/pkg/ ${ROOTFS}/var/cache/pacman/pkg
pacstrap_retry ${PACCFG} ${ROOTFS} ${BASE_BOOTSTRAP_PKGS}
echo "(1.5/6) Bootstrapping kernel..."
pacstrap_retry ${PACCFG_HWSUPPORT} ${ROOTFS} ${KERNELCHOICE} ${KERNELCHOICE}-headers

echo "(2/6) Generating fstab..."

# fstab
echo -e ${FSTAB} > ${ROOTFS}/etc/fstab

sed -i 's/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/g' ${ROOTFS}/etc/sudoers

echo "(3/6) Bootstrapping HoloISO core root"
pacstrap_retry ${PACCFG} ${ROOTFS} ${UI_BOOTSTRAP}
rm ${ROOTFS}/etc/pacman.conf
cp ${PACCFG} ${ROOTFS}/etc/pacman.conf
echo -e $OS_RELEASE > ${ROOTFS}/etc/os-release
echo -e $HOLOISO_RELEASE > ${ROOTFS}/etc/holoiso-release
echo -e $IMAGE_HOSTNAME > ${ROOTFS}/etc/hostname
arch-chroot ${ROOTFS} systemctl enable ${FLAVOR_CHROOT_SCRIPTS}
echo "(4/6) Copying postcopy items..."
if [[ -d "${SCRIPTPATH}/postcopy_${POSTCOPY_DIR}" ]]; then
	cp -r ${SCRIPTPATH}/postcopy_${POSTCOPY_DIR}/* ${ROOTFS}
	rm ${ROOTFS}/upstream.sh
	for dirs in ${MKNEWDIR}; do mkdir ${ROOTFS}$dirs; done
	if [[ -n "$FLAVOR_PLYMOUTH_THEME" ]]; then
		echo "Setting $FLAVOR_PLYMOUTH_THEME theme for plymouth bootsplash..."
		arch-chroot ${ROOTFS} plymouth-set-default-theme -R $FLAVOR_PLYMOUTH_THEME
	fi
	for binary in ${POSTCOPY_BIN_EXECUTION}; do arch-chroot ${ROOTFS} $binary && rm -rf ${ROOTFS}/usr/bin/$binary; done
	echo -e "${PACMAN_ONLOAD}" > ${ROOTFS}/usr/lib/systemd/system/var-lib-pacman.mount
	arch-chroot ${ROOTFS} systemctl enable ${FLAVOR_CHROOT_SCRIPTS}
	echo "(4.5/6) Generating en_US.UTF-8 locale..."
	sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/g' ${ROOTFS}/etc/locale.gen
	echo "/usr/bin/bash" >> ${ROOTFS}/etc/shells
	arch-chroot ${ROOTFS} locale-gen
	arch-chroot ${ROOTFS} localectl set-locale LANG=en_US.UTF-8
	echo "LANG=en_US.UTF-8" > ${ROOTFS}/etc/locale.conf
	arch-chroot ${ROOTFS} setcap 'cap_sys_nice=eip' /usr/bin/gamescope-generic
	echo "Removing unnecessary packages post-factum..."
	arch-chroot ${ROOTFS} pacman -Rns --noconfirm ${POSTREMOVE_PACKAGES}
fi

echo "(5/6) Stop doing things in container..."
# Cleanup
umount -l ${ROOTFS}/var/cache/pacman/pkg/ 2>/dev/null || true
sync

# Finish for now
echo "(6/6) Packaging snapshot..."
IMAGE="${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.img"
SNAPSHOT="${ROOT_WORKDIR}/${FLAVOR_BUILDVER}"

btrfs subvolume snapshot -r "${ROOTFS}" "${SNAPSHOT}" || exit 1

btrfs send "${SNAPSHOT}" > "${IMAGE}" || {
    echo "ERROR: btrfs send failed"
    rm -f "${IMAGE}"
    exit 1
}

if [[ ! -s "${IMAGE}" ]]; then
	echo "ERROR: btrfs send created empty image"
	rm -f "${IMAGE}"
	exit 1
fi

umount -l "${ROOTFS}/var/cache/pacman/pkg" 2>/dev/null || true
umount -l "${ROOT_WORKDIR}" 2>/dev/null || true
rm -rf "${WORKDIR}"

if [[ -z "${NO_COMPRESS}" ]]; then
	echo "Compressing image..."
	zstd --ultra -15 -T0 -f ${IMAGE} -o ${IMAGE}.zst || exit 1
	rm -rf ${IMAGE}
	chown 1000:1000 ${IMAGE}.zst
	chmod 777 ${IMAGE}.zst
fi

if [[ "${IS_HOME_BUILD}" == "true" ]]; then
	echo -e ${UPDATE_METADATA} > ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.releasemeta
	echo -e ${UPDATE_METADATA} > ${OUTPUT}/latest_${BUILD_FLAVOR_MANIFEST_ID}.releasemeta
	sha256sum ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.img.zst | awk '{print $1'} > ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.sha256
	chown 1000:1000 ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.sha256 ${OUTPUT}/latest_${BUILD_FLAVOR_MANIFEST_ID}.releasemeta
	chmod 777 ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.sha256 ${OUTPUT}/latest_${BUILD_FLAVOR_MANIFEST_ID}.releasemeta
	if [[ -n "${RC_PATH}" ]]; then
		rclone mkdir ${RC_PATH}:/download/$(echo ${OUTPUT} | sed 's#.*holoiso#holoiso#g')
		rclone copy ${OUTPUT}/latest_${BUILD_FLAVOR_MANIFEST_ID}.releasemeta ${RC_PATH}:/download/$(echo ${OUTPUT} | sed 's#.*holoiso#holoiso#g') -L --progress
		rclone copy ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.sha256 ${RC_PATH}:/${RC_ROOT}/$(echo ${OUTPUT} | sed 's#.*holoiso#holoiso#g') -L --progress
		rclone copy ${OUTPUT}/${FLAVOR_FINAL_DISTRIB_IMAGE}.img.zst ${RC_PATH}:/${RC_ROOT}/$(echo ${OUTPUT} | sed 's#.*holoiso#holoiso#g') -L --progress
	fi
fi  

echo "Build complete."

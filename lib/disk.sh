
# Usage: syncFS
function syncFS {
  printStatus "syncFS" "Flush file system buffers"
  /bin/sync >> ${ARMSTRAP_LOG_FILE} 2>&1
}

function probeFS {
  printStatus "probeFS" "Probing for partitions changes"
  /sbin/partprobe ${ARMSTRAP_DEVICE} >> ${ARMSTRAP_LOG_FILE} 2>&1
}

# Usage: makeImg <FILE> <SIZE IN MB>
function makeImg {

  printStatus "mkImage" "Creating image ${1}, size ${2}MB"
  
  if [ -e "${1}" ]; then
    printStatus "mkImage" "${1} exist"
    promptYN "${1} exist, overwrite?"
    checkStatus "Not overwriting ${1}"
  fi

  dd if=/dev/zero of=${1} bs=1M count=${2} >> ${ARMSTRAP_LOG_FILE} 2>&1
  checkStatus "dd exit with status $?"
  syncFS
}

# Usage partDevice <DEVICE> <SIZE:FS> [<SIZE:FS> ...]
function partDevice {
  local TMP_DEV="${1}"
  local TMP_OFF=1
  shift
  printStatus "partDevice" "Creating new MSDOS label on ${TMP_DEV}"
  parted ${TMP_DEV} --script -- mklabel msdos >> ${ARMSTRAP_LOG_FILE} 2>&1
  checkStatus "parted exit with status $?"
  for i in "$@"; do
    local TMP_ARR=(${i//:/ })
    if [ "${TMP_ARR[0]}" -gt "0" ]; then
      local TMP_SIZE=$(($TMP_OFF + ${TMP_ARR[0]}))
      printStatus "partDevice" "Creating a ${TMP_ARR[0]}Mb partition (${TMP_ARR[1]})" 
      parted ${TMP_DEV} --script -- mkpart primary ${TMP_ARR[1]} ${TMP_OFF} ${TMP_SIZE} >> ${ARMSTRAP_LOG_FILE} 2>&1
      checkStatus "parted exit with status $?"
      TMP_OFF=$(($TMP_SIZE + 1))
    else
      printStatus "partDevice" "Creating a partition using remaining free space (${TMP_ARR[1]})"
      parted ${TMP_DEV} --script -- mkpart primary ${TMP_ARR[1]} ${TMP_OFF} -1 >> ${ARMSTRAP_LOG_FILE} 2>&1
      checkStatus "parted exit with status $?"
    fi
  done
  probeFS  
}

# Usage loopImg <FILE>
function loopImg {
  printStatus "loopImg" "Attaching ${1} to loop device"
  ARMSTRAP_DEVICE=($(losetup -f --show "${1}"))
  checkStatus "losetup exit with status $?"
}

# Usage uloopImg
function uloopImg {
  printStatus "uloopImg" "Detaching ${ARMSTRAP_DEVICE} from loop device"
  syncFS
  losetup -d ${ARMSTRAP_DEVICE} >> ${ARMSTRAP_LOG_FILE} 2>&1
  while [ $? -ne 0 ]; do
    printStatus "uloopImg" "${ARMSTRAP_DEVICE} is busy, waiting 10 seconds before retrying"
    sleep 10
    syncFS
    losetup -d ${ARMSTRAP_DEVICE} >> ${ARMSTRAP_LOG_FILE} 2>&1
  done
}

# Usage mapImg <FILE>
function mapImg {
  local TMP_MAP
  printStatus "mapImg" "Mapping ${1} to loop device"
  while read i; do
    x=($i)
    if [ -z "${TMP_MAP}" ]; then
      TMP_MAP="/dev/mapper/${x[2]}"
    else
      TMP_MAP="${TMP_MAP} /dev/mapper/${x[2]}"
    fi
  done <<< "`kpartx -avs ${1}`"
  checkStatus "kpartx exit with status $?"
  ARMSTRAP_DEVICE_MAPS=(${TMP_MAP})
  probeFS
}

# Usage umapImg <FILE> <DEVICE>
function umapImg {
  printStatus "umapImg" "UnMapping ${1} from loop device"
  syncFS
  kpartx -d ${1} >> ${ARMSTRAP_LOG_FILE} 2>&1
  sleep 2
  kpartx -d ${2} >> ${ARMSTRAP_LOG_FILE} 2>&1
  sleep 2
  losetup -d ${2} >> ${ARMSTRAP_LOG_FILE} 2>&1
}

# Usage formatParts <DEVICE:FS> [<DEVICE:FS> ...]
function formatParts {
  for i in "$@"; do
    local TMP_ARR=(${i//:/ })
    printStatus "fmtParts" "Formatting ${TMP_ARR[0]} (${TMP_ARR[1]})"
    if [[ ${TMP_ARR[1]} = fat* ]]; then
      mkfs.vfat ${TMP_ARR[0]} >> ${ARMSTRAP_LOG_FILE} 2>&1
    else
      mkfs.${TMP_ARR[1]} -q ${TMP_ARR[0]} >> ${ARMSTRAP_LOG_FILE} 2>&1
    fi
    checkStatus "mkfs.${TMP_ARR[1]} exit with status $?"
  done
  syncFS
}

# Usage mountParts <DEVICE:MOUNTPOINT> [<DEVICE:MOUNTPOINT> ...]
function mountParts {
  probeFS
  for i in "$@"; do
    local TMP_ARR=(${i//:/ })
    checkDirectory "${TMP_ARR[1]}"
    printStatus "mountParts" "Mounting ${TMP_ARR[0]} on ${TMP_ARR[1]}"
    mount ${TMP_ARR[0]} ${TMP_ARR[1]} >> ${ARMSTRAP_LOG_FILE} 2>&1
    checkStatus "mount exit with status $?"
  done
}

# Usage umountParts <MOUNTPOINT> [<MOUNTPOINT> ...]
function umountParts {
  syncFS
  for i in "$@"; do
    printStatus "umountParts" "Unmounting ${i}"
    umount ${i} >> ${ARMSTRAP_LOG_FILE} 2>&1
    checkStatus "umount exit with status $?"
  done
}

# Usage : cleanDev <DEVICE>
function cleanDev {
  printStatus "cleanDev" "Erasing ${1}"
  dd if=/dev/zero of=${1} bs=1M count=256  >> ${ARMSTRAP_LOG_FILE} 2>&1
  checkStatus "dd exit with status $?"
  syncFS
}

# Usage setupImg <MNT_ORDER:MNT_POINT:FSTYPE:SIZE> [<MNT_ORDER:MNT_POINT:FSTYPE:SIZE>]
function setupImg {
  local TMP_PARTS=""
  local TMP_FST=""
  local TMP_FS=""
  local TMP_MNT=""
  local TMP_MT=""
  local TMP_SORT=("")
  local TMP_CNT=0
  local TMP_GUI
  
  guiStart
  TMP_GUI=$(guiWriter "start" "Setting up disk image" "Progress")

  ARMSTRAP_GUI_PCT=$(guiWriter "add" 1 "Creating disk image ${ARMSTRAP_IMAGE_NAME}")
  makeImg "${ARMSTRAP_IMAGE_NAME}" "${ARMSTRAP_IMAGE_SIZE}"
  loopImg "${ARMSTRAP_IMAGE_NAME}"
  
  for i in "$@"; do
    local TMP_ARR=(${i//:/ })
    if [ -z "${TMP_PARTS}" ]; then
      TMP_PARTS="${TMP_ARR[3]}:${TMP_ARR[2]}"
      TMP_FST="${TMP_ARR[2]}"
      TMP_MNT="${TMP_ARR[0]}:${TMP_ARR[1]}"
    else
      TMP_PARTS="${TMP_PARTS} ${TMP_ARR[3]}:${TMP_ARR[2]}"
      TMP_FST="${TMP_FST} ${TMP_ARR[2]}"
      TMP_MNT="${TMP_MNT} ${TMP_ARR[0]}:${TMP_ARR[1]}"
    fi
  done
  TMP_FST=(${TMP_FST})
  TMP_MNT=(${TMP_MNT})

  partDevice "${ARMSTRAP_DEVICE}" ${TMP_PARTS}
  
  uloopImg
  
  mapImg "${ARMSTRAP_IMAGE_NAME}"

  for i in "${ARMSTRAP_DEVICE_MAPS[@]}"; do
    if [ -z "${TMP_FS}" ]; then
      TMP_FS="${i}:${TMP_FST[$TMP_COUNT]}"
    else
      TMP_FS="${TMP_FS} ${i}:${TMP_FST[$TMP_COUNT]}"
    fi
    (( TMP_COUNT++ ))
  done
  
  ARMSTRAP_GUI_PCT=$(guiWriter "add" 5 "Formating partitions")
  formatParts ${TMP_FS}
  
  TMP_COUNT=0
  for i in "${TMP_MNT[@]}"; do
    local TMP_ARR=(${i//:/ })
    if [ -z "${TMP_MT}" ]; then
      TMP_MT="${TMP_ARR[0]}:${ARMSTRAP_DEVICE_MAPS[$TMP_COUNT]}:${ARMSTRAP_MNT}${TMP_ARR[1]}"
    else
      TMP_MT="${TMP_MT} ${TMP_ARR[0]}:${ARMSTRAP_DEVICE_MAPS[$TMP_COUNT]}:${ARMSTRAP_MNT}${TMP_ARR[1]}"
    fi
    (( TMP_COUNT++ ))
  done
  
  TMP_MT=(${TMP_MT})
  readarray -t TMP_SORT < <(printf '%s\0' "${TMP_MT[@]}" | sort -z | xargs -0n1)
  TMP_MT=(${TMP_SORT[@]})
  
  for i in "${TMP_MT[@]}"; do
    local TMP_ARR=(${i//:/ })
    if [ -z "${ARMSTRAP_MOUNT_MAP}" ]; then
      ARMSTRAP_MOUNT_MAP="${TMP_ARR[1]}:${TMP_ARR[2]}"
    else
      ARMSTRAP_MOUNT_MAP="${ARMSTRAP_MOUNT_MAP} ${TMP_ARR[1]}:${TMP_ARR[2]}"
    fi
  done
  
  ARMSTRAP_MOUNT_MAP=(${ARMSTRAP_MOUNT_MAP})
  
  ARMSTRAP_GUI_PCT=$(guiWriter "add" 4 "Mounting partitions")
  mountParts ${ARMSTRAP_MOUNT_MAP[@]}
  
  guiStop
}

function finishImg {
  local TMP_RMAP=""
  local TMP_GUI
  
  guiStart
  TMP_GUI=$(guiWriter "start" "Finishing disk image" "Progress")

  ARMSTRAP_GUI_PCT=$(guiWriter "add" 3 "Flushing buffers")
  syncFS

  for i in ${ARMSTRAP_MOUNT_MAP[@]}; do
    local TMP_ARR=(${i//:/ })
    if [ -z "${TMP_RMAP}" ]; then
      TMP_RMAP="${TMP_ARR[1]}"
    else
      TMP_RMAP="${TMP_ARR[1]} ${TMP_RMAP}"
    fi
  done
  
  TMP_RMAP=(${TMP_RMAP})
  
  ARMSTRAP_GUI_PCT=$(guiWriter "add" 1 "Unmounting image")
  umountParts ${TMP_RMAP[@]}
  umapImg "${ARMSTRAP_IMAGE_NAME}" "${ARMSTRAP_DEVICE}"
  ARMSTRAP_GUI_PCT=$(guiWriter "add" 1 "Done")
  guiStop
}

# Usage setupSD <MNT_ORDER:MNT_POINT:FSTYPE:SIZE> [<MNT_ORDER:MNT_POINT:FSTYPE:SIZE>]
function setupSD {
  local TMP_PARTS=""
  local TMP_FST=""
  local TMP_FS=""
  local TMP_MNT=""
  local TMP_MT=""
  local TMP_SORT=("")
  local TMP_CNT=0
  local TMP_GUI
  
  guiStart
  TMP_GUI=$(guiWriter "start" "Setting up SD card" "Progress")
  
  ARMSTRAP_GUI_PCT=$(guiWriter "add" 1 "Cleaning device ${ARMSTRAP_DEVICE}")
  cleanDev ${ARMSTRAP_DEVICE}
  
  for i in "$@"; do
    local TMP_ARR=(${i//:/ })
    if [ -z "${TMP_PARTS}" ]; then
      TMP_PARTS="${TMP_ARR[3]}:${TMP_ARR[2]}"
      TMP_FST="${TMP_ARR[2]}"
      TMP_MNT="${TMP_ARR[0]}:${TMP_ARR[1]}"
    else
      TMP_PARTS="${TMP_PARTS} ${TMP_ARR[3]}:${TMP_ARR[2]}"
      TMP_FST="${TMP_FST} ${TMP_ARR[2]}"
      TMP_MNT="${TMP_MNT} ${TMP_ARR[0]}:${TMP_ARR[1]}"
    fi
  done
  TMP_FST=(${TMP_FST})
  TMP_MNT=(${TMP_MNT})

  ARMSTRAP_GUI_PCT=$(guiWriter "add" 4 "Creating partitions")
  partDevice "${ARMSTRAP_DEVICE}" ${TMP_PARTS}

  ARMSTRAP_DEVICE_MAPS=""
  for i in `ls ${ARMSTRAP_DEVICE}*`; do
    if [ "${i}" != "${ARMSTRAP_DEVICE}" ]; then
      if [ -z "${ARMSTRAP_DEVICE_MAPS}" ]; then
        ARMSTRAP_DEVICE_MAPS="${i}"
      else
        ARMSTRAP_DEVICE_MAPS="${ARMSTRAP_DEVICE_MAPS} ${i}"
      fi
    fi
  done

  ARMSTRAP_DEVICE_MAPS=(${ARMSTRAP_DEVICE_MAPS})
 
  for i in "${ARMSTRAP_DEVICE_MAPS[@]}"; do
    if [ -z "${TMP_FS}" ]; then
      TMP_FS="${i}:${TMP_FST[$TMP_COUNT]}"
    else
      TMP_FS="${TMP_FS} ${i}:${TMP_FST[$TMP_COUNT]}"
    fi
    (( TMP_COUNT++ ))
  done
  
  ARMSTRAP_GUI_PCT=$(guiWriter "add" 4 "Formating partitions")
  formatParts ${TMP_FS}
  
  TMP_COUNT=0
  for i in "${TMP_MNT[@]}"; do
    local TMP_ARR=(${i//:/ })
    if [ -z "${TMP_MT}" ]; then
      TMP_MT="${TMP_ARR[0]}:${ARMSTRAP_DEVICE_MAPS[$TMP_COUNT]}:${ARMSTRAP_MNT}${TMP_ARR[1]}"
    else
      TMP_MT="${TMP_MT} ${TMP_ARR[0]}:${ARMSTRAP_DEVICE_MAPS[$TMP_COUNT]}:${ARMSTRAP_MNT}${TMP_ARR[1]}"
    fi
    (( TMP_COUNT++ ))
  done
  
  TMP_MT=(${TMP_MT})
  readarray -t TMP_SORT < <(printf '%s\0' "${TMP_MT[@]}" | sort -z | xargs -0n1)
  TMP_MT=(${TMP_SORT[@]})
  
  for i in "${TMP_MT[@]}"; do
    local TMP_ARR=(${i//:/ })
    if [ -z "${ARMSTRAP_MOUNT_MAP}" ]; then
      ARMSTRAP_MOUNT_MAP="${TMP_ARR[1]}:${TMP_ARR[2]}"
    else
      ARMSTRAP_MOUNT_MAP="${ARMSTRAP_MOUNT_MAP} ${TMP_ARR[1]}:${TMP_ARR[2]}"
    fi
  done
  
  ARMSTRAP_MOUNT_MAP=(${ARMSTRAP_MOUNT_MAP})
  
  ARMSTRAP_GUI_PCT=$(guiWriter "add" 1 "Mounting partitions")
  mountParts ${ARMSTRAP_MOUNT_MAP[@]}
  
  guiStop
}

function finishSD {
  local TMP_RMAP=""
    local TMP_GUI
  
  guiStart
  TMP_GUI=$(guiWriter "start" "Finishing SD" "Progress")

  ARMSTRAP_GUI_PCT=$(guiWriter "add" 3 "Flushing buffers")
  
  syncFS

  for i in ${ARMSTRAP_MOUNT_MAP[@]}; do
    local TMP_ARR=(${i//:/ })
    if [ -z "${TMP_RMAP}" ]; then
      TMP_RMAP="${TMP_ARR[1]}"
    else
      TMP_RMAP="${TMP_ARR[1]} ${TMP_RMAP}"
    fi
  done
  
  TMP_RMAP=(${TMP_RMAP})

  ARMSTRAP_GUI_PCT=$(guiWriter "add" 1 "Unmounting SD")  
  umountParts ${TMP_RMAP[@]}  
  ARMSTRAP_GUI_PCT=$(guiWriter "add" 1 "Done")
  guiStop
}

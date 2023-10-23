#!/bin/bash
# NAME       : cri-purge.sh
# 
# DESCRIPTION: This script will parse the output of "crictl images" to
#           determine older images that can be pruned.  Unlike "--prune"
#           option this will not delete all images that are not in use on
#           this specific node.  It will only attempt to delete old versions
#           of the image
#
# ASSUMPTION: The output of CRICTL is processed in best effort to maintain 
#           semantic version order from oldest to newest (v1.7.1, v1.8.0,
#           v1.8.1, v1.8.2, v1.9.0) with the goal to only retain the newest
#           version.
#
#           This script requires root permissions to access the CRICTL binary.
#          
AUTHOR="Richard J. Durso"
RELDATE="06/10/2023"
VERSION="0.07"
#############################################################################

###[ Define Variables ]#######################################################
CRI_CMD="crictl"
CRIINFO_CMD="crio-status"

# Skip images with these tags, let human deal with them, for example:
# SKIP_THESE_TAGS="<none> latest"
SKIP_THESE_TAGS="^\S+\s+[\w-_\.\d]+\s+"

###[ Routines ]##############################################################
__usage() {
  echo "
  cri-purge | Version: ${VERSION} | ${RELDATE} | ${AUTHOR}
  
  List and Purge downloaded cached images from containerd. 
  -----------------------------------------------------------------------------

  This script requires sudo access to CRICTL binary to obtain a list of cached
  downloaded images and remove specific older images. It will do best effort to
  honor semantic versioning always leaving the newest version of the downloaded
  image and only purge previous version(s). 

  -h, --help          : This usage statement.
  -l, --list          : List cached images and which could be purged.
  -p, --purge         : List cached images and PURGE/PRUNE older images.
  -s, --show-skipped  : List images to be skipped (humans to clean up)

  Following version tags are skipped/ignored (not deleted): ${SKIP_THESE_TAGS}

  "
}

###[ Determine ContainerD Location]##########################################
# This will parse output of CRICTL INFO looking for containerdRootDir to try
# to determine where to calculate disk space differences before and after a
# image purge.

__determine_containerd_root_dir() {
  IMAGE_STORE=$(${CRI_CMD} info | awk -F'"' '/containerdRootDir/{print $4}')

  [ -z "${IMAGE_STORE}" ] && IMAGE_STORE=$(crio-status info | awk -F'storage root: ' '/storage root:/ {print $2}')
  [ ! -d "${IMAGE_STORE}" ] && echo "NOTE: Unable to determine containerd root directory!";echo
}

###[ Generate Image List ]###################################################
# This will load a list of currently cached images that were previously
# downloaded and store this in array CRI_IMAGES. Images with TAGs defined
# in SKIP_THESE_TAGS are simply skipped - left for humans to deal with. These
# images will not be processed.  Some basic statistics are stored as well:
#
#    TOTAL_CRI_IMAGES = Integer value of images found minus skipped images
#    UNIQUE_CRI_IMAGE_NAMES = array of unique image names without version
#    TOTAL_UNIQUE_IMAGE_NAMES = Integrer value of UNIQUE_CRI_IMAGE_NAMES
#
# CRI_IMAGES will have a data lines formated as:
# docker.io/library/traefik                                  2.8.0                  b5f5bb1d51fd8       31.5MB
# docker.io/library/traefik                                  2.8.4                  9d00af07cc7c9       33.3MB
# docker.io/library/traefik                                  2.8.5                  2caeed3432ab5       33.3MB
# docker.io/library/traefik                                  2.8.7                  e3d8309b974e3       33.3MB

__generate_image_list() {

  # load list of images / filter out header line / version sort on 60th char of line
  ${CRI_CMD} images | tail -n +2 | sort -k 1.60 -V > /tmp/CRI_IMAGES

  # Filter out TAGS to SKIP
  for TAG in ${SKIP_THESE_TAGS};
  do
    grep -oP "${TAG}" /tmp/CRI_IMAGES > /tmp/CRI_IMAGES_SKIP
    if [ $(grep -c '^' /tmp/CRI_IMAGES_SKIP) -ne 0 ]; then
      echo "NOTE: Skipping Images with Tag:"
      cat /tmp/CRI_IMAGES_SKIP
      grep -vP "${TAG}" /tmp/CRI_IMAGES > /tmp/CRI_IMAGES_
      mv -f /tmp/CRI_IMAGES_ /tmp/CRI_IMAGES
      echo
    fi
  done

  TOTAL_CRI_IMAGES=$(grep -c '^' /tmp/CRI_IMAGES)

  # Reduce raw image list to unique names (without version)
  awk '{ print $1 }' /tmp/CRI_IMAGES | sort -u > /tmp/UNIQUE_CRI_IMAGE_NAMES
  TOTAL_UNIQUE_IMAGE_NAMES=$(grep -c '^' /tmp/UNIQUE_CRI_IMAGE_NAMES)
}

###[ Process Image List ]#####################################################
# List or optionally PURGE images from disk cache.  This route will attempt to
# keep one version for each uniquely named application image. Ideally the most
# recently downloaded image is retained and all older versions are purged to
# free up local disk storage.
#
# If $1 is "PURGE" then this routine will act and purge specific image(s), any
# other value will just display of a list of images that could be purged.

__process_images() {
  # Create Image List to Process
  __generate_image_list

  echo
  echo "Total Images: ${TOTAL_CRI_IMAGES} Unique Images Names: ${TOTAL_UNIQUE_IMAGE_NAMES}"
  echo
  COUNT=0
  while read IMAGE_NAME; # Do not quote UNIQUE_CRI_IMAGE_NAMES, breaks for loop
  do
    ((COUNT=COUNT+1))
    echo -n "${COUNT} / ${TOTAL_UNIQUE_IMAGE_NAMES} : Image: ${IMAGE_NAME}"

    # Find all versions of this IMAGE_NAME
    mapfile -t IMAGES <<< "$(grep "${IMAGE_NAME}" /tmp/CRI_IMAGES)"
    NUM_IMAGES=${#IMAGES[@]}

    # If only 1 version detected, keep it.
    if [[ ${NUM_IMAGES} -eq 1 ]]; then
      echo " - Keep TAG: $(echo "${IMAGES[0]}" | awk '{ printf "%s (%s)\n", $2, $4 }')"
    else
      # print last line of the array, should be one to keep.
      echo " - Keep TAG: $(printf %s\\n "${IMAGES[@]: -1}"| awk '{ printf "%s (%s)\n", $2, $4 }')"

      for (( i=0; i<$(( ${#IMAGES[@]}-1 )); i++ )) 
      do
        # Remove image if $1 == "PURGE"
        if [ "${1^^}" == "PURGE" ]; then
          echo "- Purge TAG: $( echo "${IMAGES[$i]}" | awk '{ printf "%s (%s)\n", $2, $4 }')"

          # Remove the Specific Image:TAG
          ${CRI_CMD} rmi "$(echo "${IMAGES[$i]}" |awk '{ printf "%s:%s\n", $1, $2 }')" > /dev/null 2>&1
        else
          echo "- Purgeable TAG: $( echo "${IMAGES[$i]}" | awk '{ printf "%s (%s)\n", $2, $4 }')"
        fi
      done
      echo
    fi
  done < /tmp/UNIQUE_CRI_IMAGE_NAMES
}

###[ Main Section ]##########################################################

# Confirm crictl is installed
if ! command -v ${CRI_CMD} >/dev/null 2>&1 || ! command -v ${CRIINFO_CMD} >/dev/null 2>&1 ; then
  echo
  echo "* ERROR: $CRI_CMD/$CRIINFO_CMD commands not found, install missing application or update script variable CRI_CMD/CRIINFO_CMD"
  echo
  exit 2
fi

# Confirm sudo or root equivilant access
if [ "$(id -u)" -ne 0 ]; then
  echo
  echo "* ERROR: ROOT privilege required to access CRICTL binaries."
  __usage
  exit 1
fi

__determine_containerd_root_dir

# Process argument list
if [ "$#" -ne 0 ]; then
  while [ "$#" -gt 0 ]
  do
    case "$1" in
    -h|--help)
      __usage
      exit 0
      ;;
    -v|--version)
      echo "$VERSION"
      exit 0
      ;;
    -l|--list)
      __process_images LIST
      exit 0
      ;;
    -p|--purge)
      [ -d "${IMAGE_STORE}" ] && START_DISK_SPACE=$(du -ab "${IMAGE_STORE}" | sort -n -r | head -1 | awk '{ print $1 }')
      __process_images PURGE
      [ -d "${IMAGE_STORE}" ] && END_DISK_SPACE=$(du -ab "${IMAGE_STORE}" | sort -n -r | head -1 | awk '{ print $1 }')
      echo
      [ -d "${IMAGE_STORE}" ] && echo Disk Space Change: "$(numfmt --to iec --format "%8.4f" $((START_DISK_SPACE-END_DISK_SPACE)) )"
      exit 0
      ;;
    -s|--show-skipped)
      __generate_image_list
      exit 0
      ;;
    --)
      break
      ;;
    -*)
      echo "Invalid option '$1'. Use --help to see the valid options" >&2
      exit 1
      ;;
    # an option argument, continue
    *)  ;;
    esac
    shift
  done
else
  __usage
  exit 1
fi

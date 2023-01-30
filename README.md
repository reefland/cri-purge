# CRI Purge - Cleanup Cached Kubernetes Container Images

CRI Purge, is a BASH script I wrote to help cleanup disk space of cached Kubernetes container images.  The script interacts with `crictl images` command to generate a list of cached images.  Unlike `crictl images --prune` option which will simply delete all cached images (requiring all active images to be downloaded again on next pod restart), the `cri-purge.sh` script tries to add a little intelligence to how it purges images.

* `cri-purge.sh` will process each image's list of cached versions in a best effort to determine semantic version from oldest to newest (v1.7.1, v1.8.0, v1.8.1, v1.8.2, v1.9.0) with the goal to determine and retain only the newest cached version downloaded -- Keeping the image most likely to be needed on pod restart.

* Specific tags can be defined for images to skip (do not purge).  By default the two image tags that will not be purged are `<none>` and `latest` neither of which are version specific.

* `cri-purge.sh` makes no attempt to determine if the cached images are still deployed. If you have uninstalled an application, its cached image may still be retained. `cri-purge.sh` job is just to determine the latest of whatever is currently cached, keep the latest and purge the older version(s).

* All interactions with images is via `crictl`. The `cri-purge.sh` script does not do any kind of direct manipulation of images stored or any other file system changes.

Keep in mind the latest cached downloaded image is specific to an individual node. Other nodes may have the same version or newer or older.  `cri-purge.sh` would be executed on each node individually.

* Each nodes perspective on what the latest version is will be dependant on how pods were scheduled in the past.

Lastly, not all containers use semantic versioning.  Worst case, if `cri-purge.sh` gets it wrong and the latest version is purged, then the image is simply downloaded again upon next pod restart. No worse than using `crictl images --prune`.

---

## Installation

```text
git clone https://github.com/reefland/cri-purge

chmod 775 cri-purge.sh
```

### Usage

```shell
$ ./cri-purge.sh 

* ERROR: ROOT privilege required to access CRICTL binaries.

  cri-purge: List and Purge downloaded cached images from containerd. Ver: 0.03
  -----------------------------------------------------------------------------

  This script requires sudo access to CRICTL binary to obtain a list of cached
  downloaded images and remove specific older images. It will do best effort to
  honor semantic versioning always leaving the newest version of the downloaded
  image and only delete previous version(s). 

  -h, --help          : This usage statement.
  -l, --list          : List cached images and which could be purged.
  -p, --purge         : List cached images and PURGE/PRUNE older images.
  -s, --show-skipped  : List images to be skipped (humans to clean up)

  Following version tags are skipped/ignored (not deleted): <none> latest
```

---

### Kubernetes Garbage Collection

Kubelet which is the primary node agent that runs on each node has two parameters which can help maintain disk space:

* `--image-gc-high-threshold`
* `--image-gc-low-threshold`

By default these ranges are set to 85% and 80%, meaning when the disk is 85% full  start garbage collection of images until space drops below 80%.  These values are too high for my comfort, I reduced them to 65% and 50% to keep them well below Prometheus monitoring levels.

I still use the `cri-purge.sh` script to review which images are cached and manually execute it when needed, such as while doing node maintenance before applying Ubuntu patches.

---

### To `list` Cached Images

```shell
sudo ./cri-purge.sh --list
```

The output will show the Total Images cached (all versions) and Unique Images Names cached:

```text
Total Images: 129 Unique Images Names: 67
```

The output will then present the images.  It will indicate the version tag to KEEP and indicate which version tags could be purged. Below shows where Grafana is image 7 of 67 Unique Image Names:

```text
7 / 67 : Image: docker.io/grafana/grafana - Keep TAG: 9.3.1 (97.9MB)
- Purgeable TAG: 9.1.4 (92.4MB)
- Purgeable TAG: 9.2.3 (108MB)
- Purgeable TAG: 9.2.4 (106MB)
- Purgeable TAG: 9.3.0 (97.8MB)
```

Images that do not have older versions to purge will simply list the current version to KEEP:

```text
62 / 67 : Image: registry.k8s.io/sig-storage/csi-attacher - Keep TAG: v4.0.0 (23.8MB)
63 / 67 : Image: registry.k8s.io/sig-storage/csi-node-driver-registrar - Keep TAG: v2.5.1 (9.13MB)
64 / 67 : Image: registry.k8s.io/sig-storage/csi-provisioner - Keep TAG: v3.3.0 (25.5MB)
65 / 67 : Image: registry.k8s.io/sig-storage/csi-resizer - Keep TAG: v1.6.0 (24.1MB)
66 / 67 : Image: registry.k8s.io/sig-storage/csi-snapshotter - Keep TAG: v6.1.0 (23.9MB)
```

---

### To `purge` Cached Images

```shell
sudo ./cri-purge.sh --purge
```

The output will look much the same as `list` however, this time it will indicate the version tag(s) PURGED:

```text
7 / 67 : Image: docker.io/grafana/grafana - Keep TAG: 9.3.1 (97.9MB)
- Purge TAG: 9.1.4 (92.4MB)
- Purge TAG: 9.2.3 (108MB)
- Purge TAG: 9.2.4 (106MB)
- Purge TAG: 9.3.0 (97.8MB)
```

Here `cri-purge.sh` has instructed `crictl` to remove older Grafana images `9.1.4`, `9.2.3`, `9.2.4` and `9.3.0` but keep image tag `9.3.1`.

At the end `cri-purge.sh` tries to estimate how much disk space was cleaned up:

```text
Disk Space Change:  9.7790G
```

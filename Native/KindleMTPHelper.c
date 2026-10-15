#define _DARWIN_C_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <libusb.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include "KindleMTPFileSearch.h"

#define MAX_CLIPPINGS_BYTES (20U * 1024U * 1024U)

static int limit_transfer(uint64_t sent, uint64_t total, const void *data) {
    (void)data;
    return sent > MAX_CLIPPINGS_BYTES || total > MAX_CLIPPINGS_BYTES;
}

/* Poll descriptors only: never claim/open a USB interface during detection.
 * Restrict to Amazon's PTP/MTP interfaces so older mass-storage Kindles and
 * unrelated phones remain under their existing owners. */
static int is_kindle(libusb_device *usb, struct libusb_device_descriptor *desc) {
    if (libusb_get_device_descriptor(usb, desc) != 0) return -1;
    if (desc->idVendor != 0x1949) return 0;
    for (uint8_t c = 0; c < desc->bNumConfigurations; c++) {
        struct libusb_config_descriptor *config = NULL;
        if (libusb_get_config_descriptor(usb, c, &config) != 0) {
            return -1; /* An incomplete scan must not look like an unplug. */
        }
        int found = 0;
        for (uint8_t i = 0; i < config->bNumInterfaces; i++) {
            for (int a = 0; a < config->interface[i].num_altsetting; a++) {
                const struct libusb_interface_descriptor *iface = &config->interface[i].altsetting[a];
                if (iface->bInterfaceClass == LIBUSB_CLASS_PTP &&
                    iface->bInterfaceSubClass == 1 && iface->bInterfaceProtocol == 1) {
                    found = 1;
                }
            }
        }
        libusb_free_config_descriptor(config);
        if (found) return 1;
    }
    return 0;
}

static int connection_id(libusb_device *usb, uint16_t product, char *out, size_t capacity) {
    uint8_t ports[8];
    int count = libusb_get_port_numbers(usb, ports, sizeof(ports));
    if (count <= 0) return -1;
    int used = snprintf(out, capacity, "%u-%04x", libusb_get_bus_number(usb), product);
    for (int i = 0; i < count; i++) {
        if (used < 0 || (size_t)used >= capacity) return -1;
        int added = snprintf(out + used, capacity - (size_t)used, "-%u", ports[i]);
        if (added < 0) return -1;
        used += added;
    }
    return (used < 0 || (size_t)used >= capacity) ? -1 : 0;
}

static int download(libusb_device *usb, const struct libusb_device_descriptor *desc, const char *path) {
    LIBMTP_Init();
    LIBMTP_device_entry_t *entries = NULL;
    int count = 0;
    if (LIBMTP_Get_Supported_Devices_List(&entries, &count) != 0) return 3;
    LIBMTP_raw_device_t raw = {0};
    raw.device_entry.vendor = "Amazon";
    raw.device_entry.product = "Kindle";
    raw.device_entry.vendor_id = desc->idVendor;
    raw.device_entry.product_id = desc->idProduct;
    for (int i = 0; i < count; i++) {
        if (entries[i].vendor_id == desc->idVendor && entries[i].product_id == desc->idProduct) {
            raw.device_entry = entries[i]; /* Preserve libmtp's device quirks. */
            break;
        }
    }
    raw.bus_location = libusb_get_bus_number(usb);
    raw.devnum = libusb_get_device_address(usb);
    LIBMTP_mtpdevice_t *device = LIBMTP_Open_Raw_Device_Uncached(&raw);
    if (device == NULL) return 10;

    int failed = 0;
    LIBMTP_file_t *file = NULL;
    for (LIBMTP_devicestorage_t *storage = device->storage; storage; storage = storage->next) {
        /* Only documents/My Clippings.txt is eligible for automatic import. */
        LIBMTP_file_t *root = LIBMTP_Get_Files_And_Folders(device, storage->id, LIBMTP_FILES_AND_FOLDERS_ROOT);
        if (device->errorstack != NULL) {
            print_device_errors(device);
            destroy_file_list(root);
            failed = 1;
            break;
        }
        for (LIBMTP_file_t *folder = root; folder; folder = folder->next) {
            if (folder->filetype == LIBMTP_FILETYPE_FOLDER && equals_ci(folder->filename, "documents")) {
                file = find_clippings_in_folder(device, storage->id, folder->item_id, 0, &failed);
                if (file || failed) break;
            }
        }
        destroy_file_list(root);
        if (file || failed) break;
    }
    int result = failed ? 12 : 13;
    int created = 0;
    if (file != NULL) {
        if (file->filesize > MAX_CLIPPINGS_BYTES) {
            result = 17;
        } else {
            int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR);
            if (fd < 0) {
                result = 15;
            } else {
                created = 1;
                result = LIBMTP_Get_File_To_File_Descriptor(device, file->item_id, fd, limit_transfer, NULL) == 0 ? 0 : 14;
                if (close(fd) != 0 && result == 0) result = 15;
            }
        }
        LIBMTP_destroy_file_t(file);
    }
    /* Report no filenames, serials, or clipping contents to the app logs. */
    LIBMTP_Release_Device(device);
    if (result != 0 && created) unlink(path);
    return result;
}

int main(int argc, char **argv) {
    int listing = argc == 2 && strcmp(argv[1], "list") == 0;
    if (!listing && !(argc == 4 && strcmp(argv[1], "download") == 0)) return 64;
    alarm(120); /* Also bound a USB session if Leaf quits before its child does. */
    libusb_context *context = NULL;
    if (libusb_init(&context) != 0) return 3;
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(context, &devices);
    int result = count < 0 ? 3 : (listing ? 0 : 2);
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor desc;
        int candidate = is_kindle(devices[i], &desc);
        if (candidate < 0) { result = 3; break; }
        if (!candidate) continue;
        char id[96];
        if (connection_id(devices[i], desc.idProduct, id, sizeof(id)) != 0) { result = 3; break; }
        if (listing) {
            printf("kindle:%s\n", id);
        } else if (strcmp(argv[2], id) == 0) {
            result = download(devices[i], &desc, argv[3]);
            break;
        }
    }
    if (devices) libusb_free_device_list(devices, 1);
    libusb_exit(context);
    return result;
}

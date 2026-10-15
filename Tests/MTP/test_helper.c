#include <assert.h>
#include <libmtp.h>
#include <libusb.h>
#include <stdlib.h>
#include <unistd.h>

static LIBMTP_mtpdevice_t *mock_open(LIBMTP_raw_device_t *);
static void mock_release(LIBMTP_mtpdevice_t *);
static LIBMTP_file_t *mock_listing(LIBMTP_mtpdevice_t *, uint32_t, uint32_t);
static int mock_transfer(LIBMTP_mtpdevice_t *, uint32_t, int, LIBMTP_progressfunc_t, const void *);
static int mock_descriptor(libusb_device *, struct libusb_device_descriptor *);
static int mock_config(libusb_device *, uint8_t, struct libusb_config_descriptor **);
static void mock_free_config(struct libusb_config_descriptor *);
static uint8_t mock_bus(libusb_device *);
static uint8_t mock_address(libusb_device *);
static int mock_ports(libusb_device *, uint8_t *, int);
#define LIBMTP_Open_Raw_Device_Uncached mock_open
#define LIBMTP_Release_Device mock_release
#define LIBMTP_Get_Files_And_Folders mock_listing
#define LIBMTP_Get_File_To_File_Descriptor mock_transfer
#define libusb_get_device_descriptor mock_descriptor
#define libusb_get_config_descriptor mock_config
#define libusb_free_config_descriptor mock_free_config
#define libusb_get_bus_number mock_bus
#define libusb_get_device_address mock_address
#define libusb_get_port_numbers mock_ports
#define main helper_main
#include "../../Native/KindleMTPHelper.c"
#undef main

static LIBMTP_mtpdevice_t device;
static LIBMTP_devicestorage_t storage;
static int scenario, releases, transfers;
static uint8_t address = 7;
static uint16_t vendor = 0x1949;
static uint8_t interface_class = LIBUSB_CLASS_PTP;

static LIBMTP_mtpdevice_t *mock_open(LIBMTP_raw_device_t *raw) {
    assert(raw->bus_location == 1 && raw->devnum == address);
    assert(raw->device_entry.vendor_id == 0x1949 && raw->device_entry.product_id == 0x9981);
    return &device;
}
static void mock_release(LIBMTP_mtpdevice_t *value) { assert(value == &device); releases++; }
static int mock_descriptor(libusb_device *usb, struct libusb_device_descriptor *desc) {
    (void)usb;
    memset(desc, 0, sizeof(*desc));
    desc->idVendor = vendor;
    desc->idProduct = 0x9981;
    desc->bNumConfigurations = 1;
    return 0;
}
static int mock_config(libusb_device *usb, uint8_t index, struct libusb_config_descriptor **out) {
    (void)usb; (void)index;
    static struct libusb_config_descriptor config;
    static struct libusb_interface iface;
    static struct libusb_interface_descriptor alternate;
    alternate.bInterfaceClass = interface_class;
    alternate.bInterfaceSubClass = 1;
    alternate.bInterfaceProtocol = 1;
    iface.num_altsetting = 1;
    iface.altsetting = &alternate;
    config.bNumInterfaces = 1;
    config.interface = &iface;
    *out = &config;
    return scenario == 4 ? -1 : 0;
}
static void mock_free_config(struct libusb_config_descriptor *config) { (void)config; }
static uint8_t mock_bus(libusb_device *usb) { (void)usb; return 1; }
static uint8_t mock_address(libusb_device *usb) { (void)usb; return address; }
static int mock_ports(libusb_device *usb, uint8_t *ports, int count) {
    (void)usb; assert(count >= 2); ports[0] = 3; ports[1] = 2; return 2;
}
static LIBMTP_file_t *mock_listing(LIBMTP_mtpdevice_t *value, uint32_t id, uint32_t parent) {
    assert(value == &device && id == 7);
    if (scenario == 3) return NULL;
    LIBMTP_file_t *file = LIBMTP_new_file_t();
    assert(file);
    file->item_id = parent == LIBMTP_FILES_AND_FOLDERS_ROOT ? 11 : 42;
    file->filetype = parent == LIBMTP_FILES_AND_FOLDERS_ROOT ? LIBMTP_FILETYPE_FOLDER : LIBMTP_FILETYPE_TEXT;
    file->filename = strdup(parent == LIBMTP_FILES_AND_FOLDERS_ROOT ? "Documents" : "MY CLIPPINGS.TXT");
    file->filesize = scenario == 2 ? MAX_CLIPPINGS_BYTES + 1 : 9;
    return file;
}
static int mock_transfer(LIBMTP_mtpdevice_t *value, uint32_t id, int fd,
                         LIBMTP_progressfunc_t callback, const void *data) {
    assert(value == &device && id == 42 && callback(9, 9, data) == 0);
    assert(write(fd, "synthetic", 9) == 9);
    transfers++;
    return scenario == 1 ? -1 : 0;
}

int main(void) {
    struct libusb_device_descriptor desc;
    assert(is_kindle(NULL, &desc) == 1);
    interface_class = LIBUSB_CLASS_MASS_STORAGE;
    assert(is_kindle(NULL, &desc) == 0); /* Keep mounted-volume path. */
    interface_class = LIBUSB_CLASS_PTP;
    vendor = 0x1234;
    assert(is_kindle(NULL, &desc) == 0); /* Do not claim unrelated phones. */
    vendor = 0x1949;
    scenario = 4;
    assert(is_kindle(NULL, &desc) == -1); /* Failed scan isn't an unplug. */
    scenario = 0;
    assert(is_kindle(NULL, &desc) == 1);
    char first[96], second[96];
    assert(connection_id(NULL, 0x9981, first, sizeof(first)) == 0);
    address = 8;
    assert(connection_id(NULL, 0x9981, second, sizeof(second)) == 0);
    assert(strcmp(first, second) == 0 && strcmp(first, "1-9981-3-2") == 0);
    assert(limit_transfer(MAX_CLIPPINGS_BYTES + 1, 0, NULL) != 0);
    storage.id = 7;
    device.storage = &storage;
    char directory[] = "/tmp/leaf-mtp-native-tests.XXXXXX";
    assert(mkdtemp(directory));
    char path[256];
    snprintf(path, sizeof(path), "%s/My Clippings.txt", directory);
    assert(download(NULL, &desc, path) == 0 && transfers == 1 && releases == 1);
    struct stat status;
    assert(stat(path, &status) == 0 && status.st_size == 9 && (status.st_mode & 0777) == 0600);
    assert(download(NULL, &desc, path) == 15); /* Never overwrite/unlink an existing file. */
    assert(stat(path, &status) == 0 && status.st_size == 9);
    unlink(path);
    scenario = 1;
    assert(download(NULL, &desc, path) == 14 && access(path, F_OK) != 0);
    scenario = 2;
    assert(download(NULL, &desc, path) == 17 && access(path, F_OK) != 0);
    scenario = 3;
    assert(download(NULL, &desc, path) == 13 && access(path, F_OK) != 0);
    assert(releases == 5);
    rmdir(directory);
    puts("MTP native helper tests passed: filtering, stable port identity, transfer failures, size limit and file ownership");
    return 0;
}

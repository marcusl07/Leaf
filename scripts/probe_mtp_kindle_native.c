#include <ctype.h>
#include <errno.h>
#include <inttypes.h>
#include <libmtp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int equals_ci(const char *a, const char *b) {
    if (a == NULL || b == NULL) {
        return 0;
    }

    while (*a != '\0' && *b != '\0') {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) {
            return 0;
        }
        a++;
        b++;
    }

    return *a == '\0' && *b == '\0';
}

static void print_device_errors(LIBMTP_mtpdevice_t *device) {
    if (device != NULL && device->errorstack != NULL) {
        LIBMTP_Dump_Errorstack(device);
        LIBMTP_Clear_Errorstack(device);
    }
}

static int summarize_file(const char *path, uint64_t *bytes, uint64_t *separator_count, uint64_t *metadata_line_count) {
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        fprintf(stderr, "Could not open downloaded file for summary: %s\n", strerror(errno));
        return -1;
    }

    uint64_t byte_total = 0;
    uint64_t separators = 0;
    uint64_t metadata_lines = 0;
    char line[8192];

    while (fgets(line, sizeof(line), file) != NULL) {
        size_t length = strlen(line);
        byte_total += (uint64_t)length;

        size_t trimmed = length;
        while (trimmed > 0 && (line[trimmed - 1] == '\n' || line[trimmed - 1] == '\r' || isspace((unsigned char)line[trimmed - 1]))) {
            trimmed--;
        }

        if (trimmed == 10 && strncmp(line, "==========", 10) == 0) {
            separators++;
        }

        if (strncmp(line, "- Your Highlight", 16) == 0 ||
            strncmp(line, "- Your Note", 11) == 0 ||
            strncmp(line, "- Your Bookmark", 15) == 0) {
            metadata_lines++;
        }
    }

    if (ferror(file)) {
        fprintf(stderr, "Could not read downloaded file for summary\n");
        fclose(file);
        return -1;
    }

    fclose(file);
    *bytes = byte_total;
    *separator_count = separators;
    *metadata_line_count = metadata_lines;
    return 0;
}

static void destroy_file_list(LIBMTP_file_t *files) {
    while (files != NULL) {
        LIBMTP_file_t *next = files->next;
        files->next = NULL;
        LIBMTP_destroy_file_t(files);
        files = next;
    }
}

/* Uncached devices must enumerate each folder explicitly, as mtp-files does.
 * Return a detached matching entry; callers own it. Empty folders are valid. */
static LIBMTP_file_t *find_clippings_in_folder(LIBMTP_mtpdevice_t *device,
                                              uint32_t storage, uint32_t parent,
                                              unsigned depth, int *failed) {
    if (depth >= 64) {
        fprintf(stderr, "Folder nesting exceeds probe limit\n");
        *failed = 1;
        return NULL;
    }

    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(device, storage, parent);
    if (device->errorstack != NULL) {
        fprintf(stderr, "Could not enumerate folder: storage=%u parent=%u\n", storage, parent);
        print_device_errors(device);
        destroy_file_list(files);
        *failed = 1;
        return NULL;
    }

    LIBMTP_file_t *match = NULL;
    for (LIBMTP_file_t *file = files; file != NULL; file = file->next) {
        if (file->filetype != LIBMTP_FILETYPE_FOLDER &&
            equals_ci(file->filename, "My Clippings.txt")) {
            match = LIBMTP_new_file_t();
            if (match == NULL) {
                *failed = 1;
                break;
            }
            /* Only the ID and scalar metadata are needed for the download. */
            match->item_id = file->item_id;
            match->parent_id = file->parent_id;
            match->storage_id = file->storage_id;
            match->filesize = file->filesize;
            break;
        }
        if (file->filetype == LIBMTP_FILETYPE_FOLDER) {
            match = find_clippings_in_folder(device, storage, file->item_id,
                                             depth + 1, failed);
            if (match != NULL || *failed) {
                break;
            }
        }
    }
    destroy_file_list(files);
    return match;
}

static int probe_device(LIBMTP_raw_device_t *raw_device, int device_index, const char *download_path) {
    printf("opening_device_index: %d\n", device_index);
    printf("raw_vendor: %s\n", raw_device->device_entry.vendor == NULL ? "unknown" : raw_device->device_entry.vendor);
    printf("raw_product: %s\n", raw_device->device_entry.product == NULL ? "unknown" : raw_device->device_entry.product);
    printf("raw_vendor_id: 0x%04x\n", raw_device->device_entry.vendor_id);
    printf("raw_product_id: 0x%04x\n", raw_device->device_entry.product_id);

    LIBMTP_mtpdevice_t *device = LIBMTP_Open_Raw_Device_Uncached(raw_device);
    if (device == NULL) {
        fprintf(stderr, "Could not open raw MTP device\n");
        return 10;
    }

    printf("enumerating_files: start\n");
    LIBMTP_file_t *clippings = NULL;
    int listing_failed = 0;
    for (LIBMTP_devicestorage_t *storage = device->storage;
         storage != NULL; storage = storage->next) {
        clippings = find_clippings_in_folder(device, storage->id,
                                             LIBMTP_FILES_AND_FOLDERS_ROOT,
                                             0, &listing_failed);
        if (clippings != NULL || listing_failed) {
            break;
        }
    }
    if (clippings == NULL) {
        fprintf(stderr, "%s\n", listing_failed ? "Could not read file list" :
                "My Clippings.txt was not found on this MTP device");
        LIBMTP_Release_Device(device);
        return listing_failed ? 12 : 13;
    }

    printf("selected_file_id: %u\n", clippings->item_id);
    printf("selected_file_parent: %u\n", clippings->parent_id);
    printf("selected_file_storage: %u\n", clippings->storage_id);
    printf("selected_file_reported_bytes: %" PRIu64 "\n", clippings->filesize);
    printf("selected_file_name: %s\n", "My Clippings.txt");

    printf("download: start\n");
    int download_result = LIBMTP_Get_File_To_File(device, clippings->item_id, download_path, NULL, NULL);
    if (download_result != 0) {
        fprintf(stderr, "Could not download selected file\n");
        print_device_errors(device);
        LIBMTP_destroy_file_t(clippings);
        LIBMTP_Release_Device(device);
        return 14;
    }

    uint64_t bytes = 0;
    uint64_t separators = 0;
    uint64_t metadata_lines = 0;
    if (summarize_file(download_path, &bytes, &separators, &metadata_lines) != 0) {
        LIBMTP_destroy_file_t(clippings);
        LIBMTP_Release_Device(device);
        return 15;
    }

    printf("downloaded_bytes: %" PRIu64 "\n", bytes);
    printf("separator_count: %" PRIu64 "\n", separators);
    printf("metadata_line_count: %" PRIu64 "\n", metadata_lines);
    if (bytes == 0) {
        fprintf(stderr, "Downloaded My Clippings.txt is empty\n");
        LIBMTP_destroy_file_t(clippings);
        LIBMTP_Release_Device(device);
        return 16;
    }

    printf("result: success\n");

    LIBMTP_destroy_file_t(clippings);
    LIBMTP_Release_Device(device);
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <download-path>\n", argv[0]);
        return 64;
    }

    LIBMTP_Init();

    LIBMTP_raw_device_t *raw_devices = NULL;
    int raw_device_count = 0;
    LIBMTP_error_number_t detect_result = LIBMTP_Detect_Raw_Devices(&raw_devices, &raw_device_count);
    if (detect_result == LIBMTP_ERROR_NO_DEVICE_ATTACHED) {
        fprintf(stderr, "No MTP devices attached\n");
        return 2;
    }
    if (detect_result != LIBMTP_ERROR_NONE) {
        fprintf(stderr, "Could not enumerate raw MTP devices: %d\n", detect_result);
        return 3;
    }

    printf("raw_device_count: %d\n", raw_device_count);
    int first_failure = 4;
    for (int i = 0; i < raw_device_count; i++) {
        int result = probe_device(&raw_devices[i], i, argv[1]);
        if (result == 0) {
            free(raw_devices);
            return 0;
        }
        if (first_failure == 4) {
            first_failure = result;
        }
        printf("device_index_%d_result: %d\n", i, result);
    }

    free(raw_devices);
    return first_failure;
}

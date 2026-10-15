#ifndef LEAF_KINDLE_MTP_FILE_SEARCH_H
#define LEAF_KINDLE_MTP_FILE_SEARCH_H

#include <ctype.h>
#include <libmtp.h>
#include <stdio.h>
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
#endif

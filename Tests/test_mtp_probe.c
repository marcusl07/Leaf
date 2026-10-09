#include <assert.h>
#include <libmtp.h>

static LIBMTP_file_t *mock_listing(LIBMTP_mtpdevice_t *, uint32_t, uint32_t);
#define LIBMTP_Get_Files_And_Folders mock_listing
#define main probe_main
#include "../scripts/probe_mtp_kindle_native.c"
#undef main

static int scenario;
static unsigned calls;

static LIBMTP_file_t *entry(uint32_t id, int folder, const char *name) {
    LIBMTP_file_t *file = LIBMTP_new_file_t();
    assert(file != NULL);
    file->item_id = id;
    file->filetype = folder ? LIBMTP_FILETYPE_FOLDER : LIBMTP_FILETYPE_TEXT;
    file->filename = malloc(strlen(name) + 1);
    assert(file->filename != NULL);
    strcpy(file->filename, name);
    return file;
}

static LIBMTP_file_t *mock_listing(LIBMTP_mtpdevice_t *device, uint32_t storage, uint32_t parent) {
    assert(storage == 7);
    calls++;
    if (scenario == 1) {
        device->errorstack = calloc(1, sizeof(*device->errorstack));
        assert(device->errorstack != NULL);
        device->errorstack->errornumber = LIBMTP_ERROR_GENERAL;
        device->errorstack->error_text = malloc(12);
        assert(device->errorstack->error_text != NULL);
        strcpy(device->errorstack->error_text, "mock error");
        return NULL;
    }
    if (scenario == 2) {
        return entry(parent + 1, 1, "cycle");
    }
    if (scenario == 3) {
        return NULL; /* Empty folder is not a transport error. */
    }
    if (parent == LIBMTP_FILES_AND_FOLDERS_ROOT) {
        LIBMTP_file_t *head = entry(10, 1, "empty");
        head->next = entry(11, 1, "documents");
        head->next->next = entry(12, 0, "unrelated.txt");
        return head;
    }
    if (parent == 11) {
        LIBMTP_file_t *file = entry(42, 0, "MY CLIPPINGS.TXT");
        file->parent_id = 11;
        file->storage_id = storage;
        file->filesize = 123;
        file->next = entry(43, 0, "other.txt");
        return file;
    }
    return NULL;
}

int main(void) {
    LIBMTP_mtpdevice_t device = {0};
    int failed = 0;
    LIBMTP_file_t *file = find_clippings_in_folder(&device, 7, LIBMTP_FILES_AND_FOLDERS_ROOT, 0, &failed);
    assert(!failed && file != NULL && file->item_id == 42);
    assert(file->parent_id == 11 && file->storage_id == 7 && file->filesize == 123);
    assert(file->next == NULL && calls == 3);
    LIBMTP_destroy_file_t(file);

    scenario = 3;
    assert(find_clippings_in_folder(&device, 7, 0, 0, &failed) == NULL && !failed);
    scenario = 2;
    calls = 0;
    assert(find_clippings_in_folder(&device, 7, 0, 0, &failed) == NULL && failed);
    assert(calls == 64);
    scenario = 1;
    failed = 0;
    assert(find_clippings_in_folder(&device, 7, 0, 0, &failed) == NULL && failed);
    assert(device.errorstack == NULL);
    puts("MTP enumeration tests passed");
    return 0;
}

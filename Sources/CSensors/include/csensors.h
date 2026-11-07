#ifndef CSENSORS_H
#define CSENSORS_H

#include <stdint.h>

// MARK: - SMC (System Management Controller)

typedef struct {
    uint32_t key;   // four-character code, e.g. 'Tp00'
    uint32_t size;  // payload size in bytes
    uint32_t type;  // four-character data type, e.g. 'flt '
} smc_key_t;

int smc_open(void);
void smc_close(void);
uint32_t smc_key_count(void);
int smc_key_at_index(uint32_t index, smc_key_t *out);
int smc_key_lookup(const char *name, smc_key_t *out);
int smc_read_value(const smc_key_t *key, double *out);

// MARK: - HID temperature sensors (friendly names like "NAND CH0 temp")

int hid_open(void);
int hid_service_count(void);
const char *hid_service_name(int index);
int hid_read_temperature(int index, double *out);

#endif

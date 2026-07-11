#ifndef SensorReader_h
#define SensorReader_h

typedef struct {
    double cpu; // °C, < 0 when unavailable
    double gpu; // °C, < 0 when unavailable
} MGTemps;

MGTemps mg_read_temps(void);

#endif

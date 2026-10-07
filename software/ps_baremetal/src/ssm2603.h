#ifndef SSM2603_H_
#define SSM2603_H_
#include "xiicps.h"
#define IIC_SLAVE_ADDR 0x1A
#define IIC_SCLK_RATE 100000
int ssm2603_init();
int ssm2603_reg_set(XIicPs *iic, u8 reg_addr, u16 reg_data);
#endif

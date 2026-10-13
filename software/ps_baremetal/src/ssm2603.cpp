#include "xil_printf.h"
#include "xstatus.h"

#include "ssm2603.h"
#include "xparameters.h"
#include "timer_ps.h"

namespace {

int ssm2603_write_checked(XIicPs *iic, u8 reg_addr, u16 reg_data)
{
	const int status = ssm2603_reg_set(iic, reg_addr, reg_data);
	if (status != XST_SUCCESS) {
		xil_printf("ssm2603: reg %u fail: %d\r\n", reg_addr, status);
		return status;
	}
	return XST_SUCCESS;
}

} // namespace

int ssm2603_init() {
	int Status;

	XIicPs_Config *Config;
	XIicPs Iic;

#ifdef SDT
	Config = XIicPs_LookupConfig(XPAR_XIICPS_0_BASEADDR);
#else
	Config = XIicPs_LookupConfig(XPAR_XIICPS_0_DEVICE_ID);
#endif
	if (NULL == Config) {
		xil_printf("ssm2603: XIicPs_LookupConfig failed\r\n");
		return -10;
	}

	Status = XIicPs_CfgInitialize(&Iic, Config, Config->BaseAddress);
	if (Status != XST_SUCCESS) {
		xil_printf("ssm2603: XIicPs_CfgInitialize failed: %d\r\n", Status);
		return -11;
	}

	Status = XIicPs_SelfTest(&Iic);
	if (Status != XST_SUCCESS) {
		xil_printf("ssm2603: XIicPs_SelfTest failed: %d\r\n", Status);
		return -12;
	}

	Status = XIicPs_SetSClk(&Iic, IIC_SCLK_RATE);
	if (Status != XST_SUCCESS) {
		xil_printf("ssm2603: XIicPs_SetSClk failed: %d\r\n", Status);
		return -13;
	}

	/*
	 * Write to the SSM2603 audio codec registers to configure the device. Refer to the
	 * SSM2603 Audio Codec data sheet for information on what these writes do.
	 */

	// SSM2603 Rev. D, pp. 11/17: OUT stays powered down until VMID
	// charges, ACTIVE is enabled, and the DAC path is configured.
	const u16 setup[][2] = {
		{15, 0x000}, {6, 0x077}, {0, 0x097}, {1, 0x097},
		{2, 0x079}, {3, 0x079}, {4, 0x010}, {5, 0x000},
		{7, 0x002}, // Slave I2S, 16-bit words.
		{8, 0x000}, // 12.288 MHz / 256 = 48 kHz, normal mode.
	};
	for (const auto &entry : setup) {
		Status = ssm2603_write_checked(&Iic, entry[0], entry[1]);
		if (Status != XST_SUCCESS) return Status;
	}
	TimerDelay(75000); // Zybo VMID 10 uF: C*25000/3.5 ~= 71.4 ms.
	Status = ssm2603_write_checked(&Iic, 9, 0x001);
	if (Status != XST_SUCCESS) return Status;
	Status = ssm2603_write_checked(&Iic, 6, 0x067);
	if (Status != XST_SUCCESS) return Status;

	return XST_SUCCESS;
}

int ssm2603_reg_set(XIicPs *IIcPtr, u8 regAddr, u16 regData) {
	int Status;
	u8 SendBuffer[2];

	SendBuffer[0] = regAddr << 1;
	SendBuffer[0] = SendBuffer[0] | ((regData >> 8) & 0b1);
	SendBuffer[1] = regData & 0xFF;

	Status = XIicPs_MasterSendPolled(IIcPtr, SendBuffer, 2, IIC_SLAVE_ADDR);
	if (Status != XST_SUCCESS) {
		xil_printf("IIC send failed: %d\r\n", Status);
		return Status;
	}
	/*
	 * Wait until bus is idle to start another transfer.
	 */
	while (XIicPs_BusIsBusy(IIcPtr)) {
		/* NOP */
	}
	return XST_SUCCESS;

}

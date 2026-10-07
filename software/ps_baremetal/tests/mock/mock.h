#pragma once
#include <cstdint>
#include <cstddef>
using u8 = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using UINTPTR = std::uintptr_t;
using INTPTR = std::intptr_t;
using XTime = u64;
#define XST_SUCCESS 0
#define XST_FAILURE 1
#define XST_DEVICE_IS_STARTED 2
#ifndef COUNTS_PER_SECOND
#define COUNTS_PER_SECOND 325000000ULL
#endif
#define XPAR_XSCUTIMER_0_DEVICE_ID 0
#define XPAR_XIICPS_0_DEVICE_ID 0
#define XPAR_XUSBPS_0_DEVICE_ID 0
#define XPAR_XGPIOPS_0_DEVICE_ID 0
#define XPAR_SCUGIC_0_DEVICE_ID 0
#define XPAR_XUSBPS_0_INTR 53
#define XIL_EXCEPTION_ID_IRQ_INT 5
#define XINTR_IS_LEVEL_TRIGGERED 1
#define XINTERRUPT_DEFAULT_PRIORITY 128
extern "C" void XTime_GetTime(XTime *value);
u32 Xil_In32(UINTPTR address);
void Xil_Out32(UINTPTR address, u32 value);
void Xil_Out8(UINTPTR address, u8 value);
void Xil_DCacheFlushRange(INTPTR address, u32 length);
void Xil_DCacheInvalidateRange(INTPTR address, u32 length);
int xil_printf(const char *, ...);
int usleep(unsigned int microseconds);

struct XScuTimer {};
struct XScuTimer_Config { UINTPTR BaseAddr; };
XScuTimer_Config *XScuTimer_LookupConfig(u16);
int XScuTimer_CfgInitialize(XScuTimer *, XScuTimer_Config *, UINTPTR);
void XScuTimer_SetPrescaler(XScuTimer *, u8);
void XScuTimer_Stop(XScuTimer *);
void XScuTimer_DisableAutoReload(XScuTimer *);
void XScuTimer_LoadTimer(XScuTimer *, u32);
void XScuTimer_Start(XScuTimer *);
u32 XScuTimer_GetCounterValue(XScuTimer *);
struct XIicPs {};
struct XIicPs_Config { UINTPTR BaseAddress; };
XIicPs_Config *XIicPs_LookupConfig(u16);
int XIicPs_CfgInitialize(XIicPs *, XIicPs_Config *, UINTPTR);
int XIicPs_SelfTest(XIicPs *);
int XIicPs_SetSClk(XIicPs *, u32);
int XIicPs_MasterSendPolled(XIicPs *, u8 *, int, u16);
int XIicPs_BusIsBusy(XIicPs *);

struct XGpioPs {};
struct XGpioPs_Config { UINTPTR BaseAddr; };
XGpioPs_Config *XGpioPs_LookupConfig(u16);
int XGpioPs_CfgInitialize(XGpioPs *, XGpioPs_Config *, UINTPTR);
void XGpioPs_SetDirectionPin(XGpioPs *, u32, u32);
void XGpioPs_SetOutputEnablePin(XGpioPs *, u32, u32);
void XGpioPs_WritePin(XGpioPs *, u32, u32);
using Xil_ExceptionHandler = void (*)(void *);
struct XScuGic {};
struct XScuGic_Config {};
XScuGic_Config *XScuGic_LookupConfig(u16);
int XScuGic_CfgInitialize(XScuGic *, XScuGic_Config *, UINTPTR);
void XScuGic_InterruptHandler(void *);
int XScuGic_Connect(XScuGic *, u16, Xil_ExceptionHandler, void *);
void XScuGic_SetPriorityTriggerType(XScuGic *, u16, u8, u8);
void XScuGic_Enable(XScuGic *, u16);
void XScuGic_Disable(XScuGic *, u16);
void XScuGic_Disconnect(XScuGic *, u16);
void Xil_ExceptionInit();
void Xil_ExceptionRegisterHandler(int, Xil_ExceptionHandler, void *);
void Xil_ExceptionEnable();

#define XUSBPS_EP_DIRECTION_OUT 0
#define XUSBPS_EP_DIRECTION_IN 1
#define XUSBPS_EP_EVENT_SETUP_DATA_RECEIVED 1
#define XUSBPS_EP_EVENT_DATA_RX 2
#define XUSBPS_EP_EVENT_DATA_TX 3
#define XUSBPS_EP_TYPE_CONTROL 0
#define XUSBPS_EP_TYPE_BULK 2
#define XUSBPS_IXR_UE_MASK 1
#define XUSBPS_IXR_UR_MASK 2
#define XUSBPS_IXR_UI_MASK 4
#define XUSBPS_IXR_ALL 0xFFFFFFFFU
#define XUSBPS_EPCRn_OFFSET(ep) (0x100 + (ep) * 4)
#define XUSBPS_EPCR1_OFFSET XUSBPS_EPCRn_OFFSET(1)
#define XUSBPS_EPCR_TXS_MASK 1
#define XUSBPS_EPCR_RXS_MASK 2
#define XUSBPS_EPCR_TXT_BULK_MASK 4
#define XUSBPS_EPCR_RXT_BULK_MASK 8
#define XUSBPS_EPCR_TXR_MASK 16
#define XUSBPS_EPCR_RXR_MASK 32
#define XUSBPS_OTGCSR_OFFSET 0x200
#define XUSBPS_OTGSC_OT_MASK 1
struct XUsbPs_Config { UINTPTR BaseAddress; };
struct XUsbPs { XUsbPs_Config Config; void *UserDataPtr; int CurrentAltSetting; };
struct XUsbPs_SetupData { u8 bmRequestType, bRequest; u16 wValue, wIndex, wLength; };
struct MockEpConfig { u32 Type, NumBufs, BufSize, MaxPacketSize; };
struct XUsbPs_DeviceConfig { u32 NumEndpoints, DMAMemPhys; struct {MockEpConfig In, Out;} EpCfg[2]; };
using MockEpHandler = void (*)(void *, u8, u8, void *);
XUsbPs_Config *XUsbPs_LookupConfig(u16);
int XUsbPs_CfgInitialize(XUsbPs *, XUsbPs_Config *, UINTPTR);
int XUsbPs_ConfigureDevice(XUsbPs *, XUsbPs_DeviceConfig *);
int XUsbPs_IntrSetHandler(XUsbPs *, void (*)(void *, u32), void *, u32);
int XUsbPs_EpSetHandler(XUsbPs *, u8, u8, MockEpHandler, void *);
int XUsbPs_EpGetSetupData(XUsbPs *, u8, XUsbPs_SetupData *);
int XUsbPs_EpBufferReceive(XUsbPs *, u8, u8 **, u32 *, u32 *);
void XUsbPs_EpBufferRelease(u32);
int XUsbPs_EpBufferSend(XUsbPs *, u8, u8 *, u32);
void XUsbPs_IntrHandler(void *);
void XUsbPs_IntrEnable(XUsbPs *, u32);
void XUsbPs_IntrDisable(XUsbPs *, u32);
void XUsbPs_Start(XUsbPs *);
void XUsbPs_Stop(XUsbPs *);
void XUsbPs_ClrBits(XUsbPs *, u32, u32);
void XUsbPs_SetBits(XUsbPs *, u32, u32);
u32 XUsbPs_ReadReg(UINTPTR, u32);
void XUsbPs_EpStall(XUsbPs *, u8, u8);
void XUsbPs_SetDeviceAddress(XUsbPs *, u16);
void XUsbPs_EpEnable(XUsbPs *, u8, u8);
void XUsbPs_EpPrime(XUsbPs *, u8, u8);

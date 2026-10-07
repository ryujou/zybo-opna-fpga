/************************************************************************/
/*																		*/
/*	timer_ps.h	--	Timer Delay	for Zynq systems						*/
/*																		*/
/************************************************************************/
/*	Author: Sam Bobrowicz												*/
/*	Copyright 2014, Digilent Inc.										*/
/************************************************************************/
/*  Module Description: 												*/
/*																		*/
/*		Implements an accurate delay function using the scu	timer.     	*/
/*		Code from this module will cause conflicts with other code that */
/*		requires the Zynq's scu timer.									*/
/*																		*/
/*		This module contains code from the Xilinx Demo titled			*/
/*		"xscutimer_polled_example.c"									*/
/*																		*/
/************************************************************************/
/*  Revision History:													*/
/* 																		*/
/*		2/14/2014(SamB): Created										*/
/*																		*/
/************************************************************************/
#ifndef TIMER_PS_H_
#define TIMER_PS_H_

#include "xil_types.h"
#include "xparameters.h"
#include "xtime_l.h"

/* ------------------------------------------------------------ */
/*					Miscellaneous Declarations					*/
/* ------------------------------------------------------------ */

#define TIMER_FREQ_HZ COUNTS_PER_SECOND

inline u64 TimerNowTicks()
{
	XTime ticks;
	XTime_GetTime(&ticks);
	return ticks;
}

inline u64 TimerMicrosecondsToTicks(u32 microseconds)
{
	return static_cast<u64>(microseconds) * COUNTS_PER_SECOND / 1000000ULL;
}

inline u64 TimerTicksToMicroseconds(u64 ticks)
{
	return (ticks / COUNTS_PER_SECOND) * 1000000ULL +
		(ticks % COUNTS_PER_SECOND) * 1000000ULL / COUNTS_PER_SECOND;
}

/* ------------------------------------------------------------ */
/*					Procedure Declarations						*/
/* ------------------------------------------------------------ */

int TimerInitialize(UINTPTR TimerBaseAddr);
void TimerDelay(u32 uSDelay);

/* ------------------------------------------------------------ */

/************************************************************************/


#endif /* TIMER_H_ */

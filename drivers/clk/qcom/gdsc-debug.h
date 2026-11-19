/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2021, The Linux Foundation. All rights reserved.
 */

#ifndef __QCOM_GDSC_DEBUG_H__
#define __QCOM_GDSC_DEBUG_H__

struct regulator;

#ifdef CONFIG_QCOM_CLK_GDSC_REGULATOR
void gdsc_debug_print_regs(struct regulator *regulator);
#else
/* The GDSC regulator wrapper is not built, so there is nothing to dump. */
static inline void gdsc_debug_print_regs(struct regulator *regulator) { }
#endif

#endif  /* __QCOM_GDSC_DEBUG_H__ */

/*
 * Copyright 2015-2017 NXP Semiconductors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef TFA_H_
#define TFA_H_

/* set the limit for the container file length */
#define TFA_MAX_CNT_LENGTH (256*1024)

extern struct tfa_device **devs;

struct tfa_device ** tfa_devs_create(int count);
void tfa_devs_destroy(int count);

struct tfa_device ** tfa_get_device_struct(void);

int tfa_plop_noise_interrupt(struct tfa_device *tfa, int profile, int vstep);
void tfa_lp_mode_interrupt(struct tfa_device *tfa);

#endif /* TFA_H_ */

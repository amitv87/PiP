//
//  receiver.h
//  pip
//
//  Created by Amit Verma on 30/04/22.
//  Copyright © 2022 boggyb. All rights reserved.
//
#ifndef NO_AIRPLAY

#ifndef receiver_h
#define receiver_h

#include "raop.h"

void airplay_receiver_stop(void);
void airplay_receiver_start(void);
void airplay_receiver_session_stop(raop_connection_t* conn);

#endif /* receiver_h */

#endif

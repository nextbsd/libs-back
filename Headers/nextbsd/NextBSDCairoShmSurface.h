/*
   NextBSDCairoShmSurface.h

   A cairo surface backed by NextBSD WindowServer buffers.

   Copyright (C) 2020 Free Software Foundation, Inc.
   Copyright (C) 2026 Joseph Maloney

   Adapted from WaylandCairoShmSurface.h by
   Sergio L. Pascual <slp@sinrega.org>.

   This file is part of GNUstep.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2.1 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Lesser General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; see the file COPYING.LIB.
   If not, see <http://www.gnu.org/licenses/> or write to the
   Free Software Foundation, 51 Franklin Street, Fifth Floor,
   Boston, MA 02110-1301, USA.
*/

#ifndef NextBSDCairoShmSurface_h
#define NextBSDCairoShmSurface_h

#include "cairo/CairoSurface.h"
#include <WindowServer/WSClient.h>

#define NEXTBSD_SURFACE_BUFFERS 2

/* One WindowServer buffer of a surface. */
struct nextbsd_buffer
{
  ws_buffer_t	*buffer;
  BOOL		 busy;		/* attached; waiting for buffer-release */
  BOOL		 hasStale;
  NSRect	 stale;		/* parts older than the back store */
};

/*
 * GNUstep draws into a private back store (a cairo image surface), so
 * what it drew earlier is kept between frames.  A flush copies the
 * parts of the back store a WindowServer buffer is missing into a free
 * buffer, attaches it and commits the damage.  Each window has two
 * buffers; a buffer is reused only after WindowServer has released it.
 * If neither is free, the flush is committed when one comes back.
 */
@interface NextBSDCairoShmSurface : CairoSurface
{
  int			 window;	/* window number */
  int			 width;
  int			 height;
  struct nextbsd_buffer	 buffers[NEXTBSD_SURFACE_BUFFERS];
  BOOL			 hasDamage;
  NSRect		 damage;	/* not yet committed */
  BOOL			 framePending;
}

/* WindowServer events for this surface's window. */
- (BOOL) bufferReleased: (uint32_t)bufferId;
- (void) frameDone;
/* The window is gone: drop the WindowServer buffers. */
- (void) detach;
@end

#endif

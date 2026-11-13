/* NextBSDCairoShmSurface

   A cairo surface whose pixels reach the screen through NextBSD
   WindowServer buffers (shared memory handed to the server once).

   Copyright (C) 2020 Free Software Foundation, Inc.
   Copyright (C) 2026 Joseph Maloney

   Adapted from WaylandCairoShmSurface.m by
   Sergio L. Pascual <slp@sinrega.org> and
   Riccardo Canalicchio <riccardo.canalicchio(at)gmail.com>.

   This file is part of the GNU Objective C Backend Library.

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

#include "nextbsd/NextBSDServer.h"
#include "nextbsd/NextBSDCairoShmSurface.h"
#include <Foundation/NSDebug.h>
#include <cairo.h>
#include <math.h>
#include <string.h>

/* Round a rect outwards to whole pixels and clip it to the surface. */
static BOOL
pixel_rect(NSRect r, int width, int height, int *x0, int *y0, int *x1, int *y1)
{
  *x0 = (int)floor(NSMinX(r));
  *y0 = (int)floor(NSMinY(r));
  *x1 = (int)ceil(NSMaxX(r));
  *y1 = (int)ceil(NSMaxY(r));
  if (*x0 < 0)
    *x0 = 0;
  if (*y0 < 0)
    *y0 = 0;
  if (*x1 > width)
    *x1 = width;
  if (*y1 > height)
    *y1 = height;
  return (*x1 > *x0 && *y1 > *y0);
}

static NSRect
union_rect(BOOL have, NSRect a, NSRect b)
{
  return have ? NSUnionRect(a, b) : b;
}

@implementation NextBSDCairoShmSurface

- (id) initWithDevice: (void *)device
{
  nextbsd_window_t *win = (nextbsd_window_t *)device;

  gsDevice = device;
  window = win->number;
  width = (int)NSWidth(win->frame);
  height = (int)NSHeight(win->frame);
  if (width < 1)
    width = 1;
  if (height < 1)
    height = 1;

  /* The back store GNUstep draws into. WindowServer wants premultiplied
     native-endian ARGB, which is CAIRO_FORMAT_ARGB32. HiDPI: width and
     height are points; the store has scale times the pixels, and
     cairo's device scale makes GNUstep's drawing fill them. */
  scale = [NextBSDServer backingScale];
  _surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width * scale,
					height * scale);
  if (cairo_surface_status(_surface) == CAIRO_STATUS_SUCCESS && scale != 1)
    cairo_surface_set_device_scale(_surface, scale, scale);
  if (cairo_surface_status(_surface) != CAIRO_STATUS_SUCCESS)
    {
      NSLog(@"NextBSD: can't create a %dx%d surface for window %d",
	    width, height, window);
      cairo_surface_destroy(_surface);
      _surface = NULL;
      DESTROY(self);
      return nil;
    }
  memset(buffers, 0, sizeof(buffers));
  win->surface = self;
  NSDebugLLog(@"NextBSD", @"surface %dx%d for window %d", width, height,
	      window);
  return self;
}

- (void) destroyBuffers
{
  ws_connection_t *conn = [NextBSDServer connection];
  int i;

  for (i = 0; i < NEXTBSD_SURFACE_BUFFERS; i++)
    {
      if (buffers[i].buffer != NULL && conn != NULL)
	{
	  ws_buffer_destroy(conn, buffers[i].buffer);
	}
      buffers[i].buffer = NULL;
      buffers[i].busy = NO;
    }
}

- (void) dealloc
{
  NextBSDServer *srv = (NextBSDServer *)GSCurrentServer();

  if (window != 0 && [srv isKindOfClass: [NextBSDServer class]])
    {
      nextbsd_window_t *win = [srv windowWithNumber: window];

      if (win != NULL && win->surface == self)
	{
	  win->surface = nil;
	}
    }
  [self destroyBuffers];
  [super dealloc];
}

- (void) detach
{
  [self destroyBuffers];
  window = 0;
  hasDamage = NO;
}

- (NSSize) size
{
  return NSMakeSize(width, height);
}

- (void) setSize: (NSSize)newSize
{
  /* A new size gets a new surface from -setWindowdevice:forContext:. */
}

/* Find a buffer WindowServer isn't holding, creating it if needed. */
- (struct nextbsd_buffer *) freeBuffer
{
  ws_connection_t *conn = [NextBSDServer connection];
  int i;

  for (i = 0; i < NEXTBSD_SURFACE_BUFFERS; i++)
    {
      if (buffers[i].buffer != NULL && !buffers[i].busy)
	{
	  return &buffers[i];
	}
    }
  for (i = 0; i < NEXTBSD_SURFACE_BUFFERS; i++)
    {
      if (buffers[i].buffer == NULL)
	{
	  buffers[i].buffer = ws_buffer_create(conn,
	    (uint32_t)(width * scale), (uint32_t)(height * scale),
	    (uint32_t)scale);
	  if (buffers[i].buffer == NULL)
	    {
	      NSLog(@"NextBSD: can't create a %dx%d buffer for window %d: %s",
		    width, height, window, strerror(errno));
	      return NULL;
	    }
	  buffers[i].busy = NO;
	  buffers[i].hasStale = YES;
	  buffers[i].stale = NSMakeRect(0, 0, width, height);
	  return &buffers[i];
	}
    }
  return NULL;
}

/* Bring a buffer up to date with the back store. */
- (void) updateBuffer: (struct nextbsd_buffer *)b
{
  const uint8_t *src;
  uint8_t	*dst;
  int		 sstride, dstride, x0, y0, x1, y1, y;

  if (!b->hasStale)
    return;
  b->hasStale = NO;
  if (!pixel_rect(b->stale, width, height, &x0, &y0, &x1, &y1))
    return;
  cairo_surface_flush(_surface);
  src = cairo_image_surface_get_data(_surface);
  sstride = cairo_image_surface_get_stride(_surface);
  dst = ws_buffer_data(b->buffer);
  dstride = (int)ws_buffer_stride(b->buffer);
  if (src == NULL || dst == NULL)
    return;
  /* points -> the store's pixels */
  x0 *= scale;
  y0 *= scale;
  x1 *= scale;
  y1 *= scale;
  for (y = y0; y < y1; y++)
    {
      memcpy(dst + (size_t)y * dstride + (size_t)x0 * 4,
	     src + (size_t)y * sstride + (size_t)x0 * 4,
	     (size_t)(x1 - x0) * 4);
    }
}

/* Attach a free buffer and commit the damage, if a buffer is free. */
- (void) commit
{
  ws_connection_t	*conn = [NextBSDServer connection];
  struct nextbsd_buffer *b;
  ws_rect_t		 r;
  int			 x0, y0, x1, y1;

  if (!hasDamage || window == 0 || conn == NULL)
    return;
  b = [self freeBuffer];
  if (b == NULL)
    {
      /* Both buffers are with WindowServer; commit on buffer-release. */
      return;
    }
  [self updateBuffer: b];
  hasDamage = NO;
  if (!pixel_rect(damage, width, height, &x0, &y0, &x1, &y1))
    return;
  r.x = x0;
  r.y = y0;
  r.width = x1 - x0;
  r.height = y1 - y0;
  ws_window_attach(conn, window, b->buffer);
  ws_window_damage(conn, window, &r, 1);
  ws_window_commit(conn, window, WS_COMMIT_FRAME_DONE);
  b->busy = YES;
  framePending = YES;
}

/* rect is in window pixels with a top-left origin. */
- (void) handleExposeRect: (NSRect)rect
{
  int i;

  if (window == 0 || NSIsEmptyRect(rect))
    return;
  for (i = 0; i < NEXTBSD_SURFACE_BUFFERS; i++)
    {
      if (buffers[i].buffer != NULL)
	{
	  buffers[i].stale = union_rect(buffers[i].hasStale,
					buffers[i].stale, rect);
	  buffers[i].hasStale = YES;
	}
    }
  damage = union_rect(hasDamage, damage, rect);
  hasDamage = YES;
  [self commit];
}

/*
 * -[NSWindow flushWindow] never calls -flushwindowrect:: for a window
 * with NSBackingStoreNonretained (an NSComboBox's drop-down list, for
 * one); it only flushes the graphics context, which ends up here. The
 * X11 surface draws straight into the window, but this one draws into
 * the back store, so put all of it on screen.
 */
- (void) flush
{
  nextbsd_window_t *win = (nextbsd_window_t *)gsDevice;

  if (window == 0 || win == NULL || win->surface != self
      || win->type != NSBackingStoreNonretained)
    return;
  [self handleExposeRect: NSMakeRect(0, 0, width, height)];
}

- (BOOL) bufferReleased: (uint32_t)bufferId
{
  int i;

  for (i = 0; i < NEXTBSD_SURFACE_BUFFERS; i++)
    {
      if (buffers[i].buffer != NULL
	  && ws_buffer_id(buffers[i].buffer) == bufferId)
	{
	  buffers[i].busy = NO;
	  [self commit];
	  return YES;
	}
    }
  return NO;
}

- (void) frameDone
{
  framePending = NO;
  [self commit];
}

@end

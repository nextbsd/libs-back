/*
   NextBSDServer+Cursor - cursors on the NextBSD WindowServer

   Copyright (C) 2026 Joseph Maloney

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

#include "config.h"
#include <AppKit/NSBitmapImageRep.h>
#include <AppKit/NSColor.h>
#include <AppKit/NSCursor.h>
#include <AppKit/NSGraphics.h>
#include <AppKit/NSImage.h>
#include <Foundation/NSDebug.h>

#include <stdlib.h>

#include "nextbsd/NextBSDServer.h"

/* WindowServer's standard cursor for a libs-gui one. */
static uint32_t
ws_cursor_kind(int style)
{
  switch (style)
    {
    case GSIBeamCursor:			return WS_CURSOR_IBEAM;
    case GSPointingHandCursor:		return WS_CURSOR_POINTING_HAND;
    case GSClosedHandCursor:		return WS_CURSOR_CLOSED_HAND;
    case GSOpenHandCursor:		return WS_CURSOR_OPEN_HAND;
    case GSCrosshairCursor:		return WS_CURSOR_CROSSHAIR;
    case GSResizeLeftCursor:
    case GSResizeRightCursor:
    case GSResizeLeftRightCursor:	return WS_CURSOR_RESIZE_LR;
    case GSResizeUpCursor:
    case GSResizeDownCursor:
    case GSResizeUpDownCursor:		return WS_CURSOR_RESIZE_UD;
    case GSOperationNotAllowedCursor:
    case GSDisappearingItemCursor:	return WS_CURSOR_NOT_ALLOWED;
    default:				return WS_CURSOR_ARROW;
    }
}

@implementation NextBSDServer (Cursor)

- (void) setupCursors
{
  [self standardcursor: GSArrowCursor : (void **)&arrowCursor];
  currentCursor = arrowCursor;
}

- (void) hidecursor
{
  if (!cursorHidden)
    {
      cursorHidden = YES;
      ws_set_cursor_visible(conn, 0);
    }
}

- (void) showcursor
{
  if (cursorHidden)
    {
      cursorHidden = NO;
      ws_set_cursor_visible(conn, 1);
    }
}

- (void) standardcursor: (int)style : (void **)cid
{
  nextbsd_cursor_t *c = calloc(1, sizeof(*c));

  c->kind = ws_cursor_kind(style);
  *cid = c;
}

/* A custom cursor: the image goes into a WindowServer buffer. */
- (void) imagecursor: (NSPoint)hotp : (NSImage *)image : (void **)cid
{
  NSBitmapImageRep *rep;
  nextbsd_cursor_t *c;
  ws_buffer_t	   *b;
  uint32_t	   *pixels;
  uint32_t	    stride;
  NSInteger	    w, h, x, y;

  *cid = NULL;
  if (image == nil)
    return;
  rep = [NSBitmapImageRep imageRepWithData: [image TIFFRepresentation]];
  w = [rep pixelsWide];
  h = [rep pixelsHigh];
  if (rep == nil || w <= 0 || h <= 0 || w > 256 || h > 256)
    return;
  b = ws_buffer_create(conn, (uint32_t)w, (uint32_t)h, 1);
  if (b == NULL)
    return;
  pixels = ws_buffer_data(b);
  stride = ws_buffer_stride(b) / 4;
  for (y = 0; y < h; y++)
    {
      for (x = 0; x < w; x++)
	{
	  NSColor *col = [[rep colorAtX: x y: y]
	    colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
	  CGFloat r = 0, g = 0, bl = 0, a = 0;
	  uint32_t ia;

	  [col getRed: &r green: &g blue: &bl alpha: &a];
	  ia = (uint32_t)(a * 255.0 + 0.5);
	  /* premultiplied ARGB */
	  pixels[y * stride + x] = (ia << 24)
	    | ((uint32_t)(r * a * 255.0 + 0.5) << 16)
	    | ((uint32_t)(g * a * 255.0 + 0.5) << 8)
	    | (uint32_t)(bl * a * 255.0 + 0.5);
	}
    }
  c = calloc(1, sizeof(*c));
  c->kind = WS_CURSOR_CUSTOM;
  c->image = b;
  c->hot_x = (int32_t)MAX(0, MIN(hotp.x, w - 1));
  c->hot_y = (int32_t)MAX(0, MIN(hotp.y, h - 1));
  *cid = c;
}

- (void) setcursorcolor: (NSColor *)fg : (NSColor *)bg : (void *)cid
{
  NSLog(@"Call to obsolete method -setcursorcolor:::");
  [self recolorcursor: fg : bg : cid];
  [self setcursor: cid];
}

- (void) recolorcursor: (NSColor *)fg : (NSColor *)bg : (void *)cid
{
  /* WindowServer's cursors have fixed colours. */
}

- (void) setcursor: (void *)cid
{
  nextbsd_cursor_t *c = cid;

  if (c == NULL || c == currentCursor)
    return;
  currentCursor = c;
  ws_set_cursor(conn, c->kind, c->image, c->hot_x, c->hot_y);
}

- (void) freecursor: (void *)cid
{
  nextbsd_cursor_t *c = cid;

  if (c == NULL || c == arrowCursor)
    return;
  if (c == currentCursor)
    currentCursor = NULL;
  if (c->image != NULL)
    ws_buffer_destroy(conn, c->image);
  free(c);
}

@end

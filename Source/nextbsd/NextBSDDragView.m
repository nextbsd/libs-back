/*
   NextBSDDragView - drag and drop through the NextBSD WindowServer

   Copyright (C) 2026 Joseph Maloney <pkgdemonteam@gmail.com>

   This file is part of the GNUstep Backend.

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
#include <AppKit/NSApplication.h>
#include <AppKit/NSBitmapImageRep.h>
#include <AppKit/NSCell.h>
#include <AppKit/NSEvent.h>
#include <AppKit/NSGraphics.h>
#include <AppKit/NSGraphicsContext.h>
#include <AppKit/NSImage.h>
#include <AppKit/NSPasteboard.h>
#include <AppKit/NSWindow.h>
#include <Foundation/NSArray.h>
#include <Foundation/NSDate.h>
#include <Foundation/NSDebug.h>
#include <Foundation/NSException.h>
#include <Foundation/NSString.h>

#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "nextbsd/NextBSDServer.h"
#include "nextbsd/NextBSDDragView.h"

@interface NSApplication (GNUstepPrivate)
- (void) _postAndSendEvent: (NSEvent *)anEvent;
@end

static NextBSDDragView *sharedDragView = nil;

#ifdef WS_SERVER_DRAG
/* NSDragOperation and WS_DRAG_OP_* have the same bits; Every is all. */
static uint32_t
ws_ops(NSDragOperation ops)
{
  return (ops >= 0xffffffffu) ? WS_DRAG_OP_EVERY : (uint32_t)ops;
}

static NSDragOperation
ns_ops(uint32_t ops)
{
  return (ops == WS_DRAG_OP_EVERY) ? NSDragOperationEvery
    : (NSDragOperation)ops;
}
#endif

@implementation NextBSDDragView

+ (id) sharedDragView
{
  if (sharedDragView == nil)
    sharedDragView = [NextBSDDragView new];
  return sharedDragView;
}

/* Can WindowServer carry drags between apps? */
+ (BOOL) serverDrags
{
#ifdef WS_SERVER_DRAG
  ws_connection_t *conn = [NextBSDServer connection];

  return conn != NULL && (ws_server_flags(conn) & WS_SERVER_DRAG) != 0;
#else
  return NO;
#endif
}

#ifdef WS_SERVER_DRAG

- (NextBSDServer *) _server
{
  return (NextBSDServer *)GSCurrentServer();
}

/* GNUstep screen coordinates of a WindowServer screen position. */
- (NSPoint) _screenPoint: (double)x : (double)y
{
  return NSMakePoint(x, [[self _server] screenHeight] - y);
}

/*
 * The drag image as a WindowServer buffer: premultiplied ARGB8888, drawn
 * with cairo into a bitmap, as the backend draws the app icon. NULL if
 * there's no image or it's too large.
 */
- (ws_buffer_t *) _bufferForImage: (NSImage *)image
{
  ws_connection_t   *conn = [NextBSDServer connection];
  NSSize	     size = [image size];
  NSBitmapImageRep  *rep;
  NSGraphicsContext *ctx, *old;
  ws_buffer_t	    *b;
  unsigned char	    *p;
  uint32_t	    *px, stride;
  int		     s = [NextBSDServer backingScale];
  int		     w = (int)ceil(size.width), h = (int)ceil(size.height);
  int		     x, y;

  if (image == nil || w <= 0 || h <= 0 || w > WS_MAX_DRAG_IMAGE
      || h > WS_MAX_DRAG_IMAGE)
    return NULL;
  /* HiDPI: drawn at the backing scale, sharp; the hot spot stays in
     points */
  w *= s;
  h *= s;
  rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL
						 pixelsWide: w
						 pixelsHigh: h
					      bitsPerSample: 8
					    samplesPerPixel: 4
						   hasAlpha: YES
						   isPlanar: NO
					     colorSpaceName: NSDeviceRGBColorSpace
						bytesPerRow: w * 4
					       bitsPerPixel: 32];
  if (rep == nil)
    return NULL;
  memset([rep bitmapData], 0, (size_t)w * h * 4);
  ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep: rep];
  if (ctx == nil)
    {
      RELEASE(rep);
      return NULL;
    }
  old = [NSGraphicsContext currentContext];
  [NSGraphicsContext setCurrentContext: ctx];
  NS_DURING
    {
      [image drawInRect: NSMakeRect(0, 0, w, h)
	       fromRect: NSZeroRect
	      operation: NSCompositeSourceOver
	       fraction: 1.0];
      [ctx flushGraphics];
    }
  NS_HANDLER
    {
      NSLog(@"NextBSD: can't draw the drag image: %@", localException);
    }
  NS_ENDHANDLER
  [NSGraphicsContext setCurrentContext: old];

  b = ws_buffer_create(conn, (uint32_t)w, (uint32_t)h, (uint32_t)s);
  if (b != NULL)
    {
      /* The bitmap is RGBA, premultiplied, top row first. */
      p = [rep bitmapData];
      px = ws_buffer_data(b);
      stride = ws_buffer_stride(b) / 4;
      for (y = 0; y < h; y++)
	for (x = 0; x < w; x++, p += 4)
	  px[y * stride + x] = ((uint32_t)p[3] << 24)
	    | ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8)
	    | (uint32_t)p[2];
    }
  RELEASE(rep);
  return b;
}

/* ---- the source ---- */

/*
 * The source's operations, the way GSDragView asks for them: one mask
 * for this app's windows, one for other apps'.
 */
- (NSDragOperation) _sourceMaskForLocal: (BOOL)local
{
  if ([dragSource respondsToSelector:
		    @selector(draggingSourceOperationMaskForLocal:)])
    return [dragSource draggingSourceOperationMaskForLocal: local];
  return NSDragOperationCopy | NSDragOperationLink
    | NSDragOperationGeneric | NSDragOperationPrivate;
}

/* Events while WindowServer has the drag: keep the app's windows up to
   date, give drag events for its windows to them, swallow the rest of
   the pointer and modifier events (WindowServer handles those). */
- (void) _handleEventDuringServerDrag: (NSEvent *)e
{
  if ([e type] != NSAppKitDefined)
    return;
  switch ([e subtype])
    {
    case GSAppKitWindowMoved:
    case GSAppKitWindowResized:
    case GSAppKitRegionExposed:
    case GSAppKitDraggingEnter:
    case GSAppKitDraggingUpdate:
    case GSAppKitDraggingExit:
    case GSAppKitDraggingDrop:
      [NSApp sendEvent: e];
      break;
    case GSAppKitDraggingFinished:
      /* our wake-up (-takeDragEvent:, WS_EVENT_DRAG_END) */
      break;
    default:
      NSDebugLLog(@"NSDragging", @"dropped NSAppKitDefined (%d) event "
		  @"during a drag", (int)[e subtype]);
      break;
    }
}

- (void) dragImage: (NSImage*)anImage
		at: (NSPoint)screenLocation
	    offset: (NSSize)initialOffset
	     event: (NSEvent*)event
	pasteboard: (NSPasteboard*)pboard
	    source: (id)sourceObject
	 slideBack: (BOOL)slideFlag
{
  ws_connection_t  *conn = [NextBSDServer connection];
  NextBSDServer	   *srv = [self _server];
  NSUInteger	    eventMask = NSLeftMouseDownMask | NSLeftMouseUpMask
    | NSLeftMouseDraggedMask | NSRightMouseDownMask | NSRightMouseUpMask
    | NSRightMouseDraggedMask | NSOtherMouseDownMask | NSOtherMouseUpMask
    | NSOtherMouseDraggedMask | NSMouseMovedMask | NSAppKitDefinedMask
    | NSFlagsChangedMask;
  NSDate	   *future = [NSDate distantFuture];
  NSArray	   *types;
  const char	  **ctypes = NULL;
  ws_drag_params_t  p;
  ws_buffer_t	   *buf;
  NSPoint	    eventPoint, imagePoint, startPoint;
  NSSize	    imageSize;
  NSEvent	   *e;
  NSUInteger	    i, ntypes;
  uint32_t	    s = 0;
  int		    r;

  if (![NextBSDDragView serverDrags])
    {
      [super dragImage: anImage
		    at: screenLocation
		offset: initialOffset
		 event: event
	    pasteboard: pboard
		source: sourceObject
	     slideBack: slideFlag];
      return;
    }

  ASSIGN(dragPasteboard, pboard);
  ASSIGN(dragSource, sourceObject);
  dragSequence = [event timestamp];
  slideBack = slideFlag;
  targetWindowRef = 0;
  targetMask = NSDragOperationEvery;
  destExternal = NO;
  destWindow = nil;
  if (anImage == nil)
    anImage = [NSImage imageNamed: @"common_Close"];
  [dragCell setImage: anImage];
  imageSize = [anImage size];

  /* Where the pointer is, and where the image is, as GSDragView works
     them out: offset is the pointer's place in the image. */
  eventPoint = [[event window] convertBaseToScreen: [event locationInWindow]];
  eventPoint.x += initialOffset.width;
  eventPoint.y += initialOffset.height;
  imagePoint = screenLocation;
  imagePoint.x += initialOffset.width;
  imagePoint.y += initialOffset.height;
  offset.width = eventPoint.x - imagePoint.x;
  offset.height = eventPoint.y - imagePoint.y;
  dragPosition = newPosition = eventPoint;

  if ([dragSource respondsToSelector:
		    @selector(ignoreModifierKeysWhileDragging)]
      && [dragSource ignoreModifierKeysWhileDragging])
    operationMask = NSDragOperationIgnoresModifiers;
  else
    operationMask = NSDragOperationEvery;
  dragMask = [self _sourceMaskForLocal: YES];

  types = [pboard types];
  ntypes = [types count];
  if (ntypes > 0)
    ctypes = malloc(ntypes * sizeof(*ctypes));
  for (i = 0; ctypes != NULL && i < ntypes; i++)
    ctypes[i] = [[types objectAtIndex: i] UTF8String];

  buf = [self _bufferForImage: anImage];
  memset(&p, 0, sizeof(p));
  p.window = (uint32_t)[[event window] windowNumber];
  p.image = buf;
  /* WindowServer's images are top-left based. */
  p.hot_x = (int32_t)offset.width;
  p.hot_y = (int32_t)(imageSize.height - offset.height);
  p.ops_local = ws_ops([self _sourceMaskForLocal: YES]);
  p.ops_external = ws_ops([self _sourceMaskForLocal: NO]);
  p.flags = (slideFlag ? WS_DRAG_SLIDE_BACK : 0)
    | (operationMask == NSDragOperationIgnoresModifiers
       ? WS_DRAG_IGNORE_MODIFIERS : 0);
  p.slide_x = (int32_t)screenLocation.x;
  p.slide_y = (int32_t)([srv screenHeight] - screenLocation.y
			- imageSize.height);
  p.pasteboard = [[pboard name] UTF8String];
  p.types = ctypes;
  p.ntypes = (unsigned)ntypes;
  session = 0;
  ended = NO;
  r = ws_drag_begin(conn, &p, &s);
  if (buf != NULL)
    ws_buffer_destroy(conn, buf);
  free(ctypes);
  if (r < 0)
    {
      /* Not started from a press WindowServer knows of (a drag begun
	 after the button went up): GSDragView's drag, inside the app. */
      NSDebugLLog(@"NSDragging", @"ws_drag_begin: %s", strerror(errno));
      DESTROY(dragSource);
      DESTROY(dragPasteboard);
      [super dragImage: anImage
		    at: screenLocation
		offset: initialOffset
		 event: event
	    pasteboard: pboard
		source: sourceObject
	     slideBack: slideFlag];
      return;
    }
  session = s;
  isDragging = YES;
  NSDebugLLog(@"NSDragging", @"drag %u: %@", session, types);
  [srv scheduleDispatch];

  startPoint = NSMakePoint(eventPoint.x - offset.width,
			   eventPoint.y - offset.height);
  if ([dragSource respondsToSelector: @selector(draggedImage:beganAt:)])
    [dragSource draggedImage: anImage beganAt: startPoint];

  /* WindowServer has the drag until WS_EVENT_DRAG_END. */
  while (!ended)
    {
      e = [NSApp nextEventMatchingMask: eventMask
			     untilDate: future
				inMode: NSEventTrackingRunLoopMode
			       dequeue: YES];
      if (e != nil)
	[self _handleEventDuringServerDrag: e];
    }
  /* A drop on one of our own windows came just before the end. */
  while ((e = [NSApp nextEventMatchingMask: NSAppKitDefinedMask
				 untilDate: [NSDate distantPast]
				    inMode: NSEventTrackingRunLoopMode
				   dequeue: YES]) != nil)
    [self _handleEventDuringServerDrag: e];

  dragPosition = endPoint;
  NSDebugLLog(@"NSDragging", @"drag %u ended: operation 0x%x flags 0x%x",
	      session, endOperation, endFlags);
  if ([dragSource respondsToSelector:
		    @selector(draggedImage:endedAt:operation:)])
    {
      [dragSource draggedImage: anImage
		       endedAt: NSMakePoint(endPoint.x - offset.width,
					    endPoint.y - offset.height)
		     operation: ns_ops(endOperation)];
    }
  else if ([dragSource respondsToSelector:
			 @selector(draggedImage:endedAt:deposited:)])
    {
      [dragSource draggedImage: anImage
		       endedAt: NSMakePoint(endPoint.x - offset.width,
					    endPoint.y - offset.height)
		     deposited: (endFlags & WS_DRAG_END_DROPPED) != 0];
    }
  isDragging = NO;
  session = 0;
  destWindow = nil;
  DESTROY(dragSource);
  DESTROY(dragPasteboard);
}

/* ---- the destination ---- */

/*
 * The drag in the destination window, from where it is on the screen,
 * worked out when the destination asks: the drag events wait in the
 * queue, and the destination may move its window before it gets to
 * them (the Dock moves its tiles to open a drop slot), so a point taken
 * against the window's frame when WindowServer's event came would be
 * off by as much as the window moved.
 */
- (NSPoint) draggingLocation
{
  if ([NextBSDDragView serverDrags] && destWindow != nil)
    return [destWindow convertScreenToBase: dragPosition];
  return [super draggingLocation];
}

- (NSPoint) draggedImageLocation
{
  NSPoint loc = [self draggingLocation];

  if (dragSource)
    {
      loc.x -= offset.width;
      loc.y -= offset.height;
    }
  return loc;
}

- (void) _postDragSubtype: (GSAppKitSubtype)subtype
		   window: (NSWindow *)win
		  session: (uint32_t)sess
		      ops: (NSDragOperation)ops
{
  NSEvent *e;

  e = [NSEvent otherEventWithType: NSAppKitDefined
			 location: dragPoint
		    modifierFlags: 0
			timestamp: 0
		     windowNumber: [win windowNumber]
			  context: GSCurrentContext()
			  subtype: subtype
			    data1: sess
			    data2: ops];
  [[self _server] postEvent: e atStart: NO];
}

- (void) takeDragEvent: (const ws_event_t *)ev
{
  ws_connection_t *conn = [NextBSDServer connection];
  NSWindow	  *win;
  GSAppKitSubtype  subtype;
  NSPoint	   screenPoint;
  BOOL		   local;

  switch (ev->hdr.type)
    {
    case WS_EVENT_DRAG_STATUS:
      /* WindowServer shows the cursor itself. */
      NSDebugLLog(@"NSDragging", @"drag %u: window %u takes 0x%x",
		  ev->u.drag_status.session, ev->u.drag_status.target,
		  ev->u.drag_status.operation);
      return;

    case WS_EVENT_DRAG_END:
      if (ev->u.drag_end.session != session || session == 0)
	return;
      ended = YES;
      endOperation = ev->u.drag_end.operation;
      endFlags = ev->u.drag_end.flags;
      endPoint = [self _screenPoint: ev->u.drag_end.screen_x
				    : ev->u.drag_end.screen_y];
      /* Wake the drag loop up. */
      [[self _server] postEvent:
	[NSEvent otherEventWithType: NSAppKitDefined
			   location: NSZeroPoint
		      modifierFlags: 0
			  timestamp: 0
		       windowNumber: [_window windowNumber]
			    context: GSCurrentContext()
			    subtype: GSAppKitDraggingFinished
			      data1: 0
			      data2: 0]
			atStart: NO];
      return;

    case WS_EVENT_DRAG:
      break;

    default:
      return;
    }

  win = GSWindowWithNumber(ev->hdr.window);
  if (win == nil)
    {
      /* Not a window libs-gui knows (any more): it takes nothing. */
      if (ev->u.drag.phase == WS_DRAG_ENTER
	  || ev->u.drag.phase == WS_DRAG_UPDATE)
	ws_drag_status(conn, ev->u.drag.session, ev->hdr.window,
		       WS_DRAG_OP_NONE, 0);
      return;
    }

  /* Our own drag over one of our windows keeps its source; another
     app's has none, and its data is on the pasteboard it names. */
  local = (isDragging && session != 0 && ev->u.drag.session == session);
  if (!local)
    {
      if (dragSource != nil && !isDragging)
	DESTROY(dragSource);
      if (dragPasteboard == nil || ev->u.drag.phase == WS_DRAG_ENTER)
	{
	  NSString *name = [NSString stringWithUTF8String:
				       ev->u.drag.pasteboard];

	  if ([name length] == 0)
	    name = NSDragPboard;
	  ASSIGN(dragPasteboard, [NSPasteboard pasteboardWithName: name]);
	}
      dragSequence = ev->u.drag.session;
      destExternal = YES;
    }
  dragMask = ns_ops(ev->u.drag.operations);
  operationMask = NSDragOperationEvery;
  destWindow = win;
  screenPoint = [self _screenPoint: ev->u.drag.screen_x
				  : ev->u.drag.screen_y];
  dragPosition = screenPoint;
  dragPoint = [win convertScreenToBase: screenPoint];

  switch (ev->u.drag.phase)
    {
    case WS_DRAG_ENTER:  subtype = GSAppKitDraggingEnter; break;
    case WS_DRAG_UPDATE: subtype = GSAppKitDraggingUpdate; break;
    case WS_DRAG_EXIT:   subtype = GSAppKitDraggingExit; break;
    case WS_DRAG_DROP:   subtype = GSAppKitDraggingDrop; break;
    default:		 return;
    }
  [self _postDragSubtype: subtype
		  window: win
		 session: ev->u.drag.session
		     ops: dragMask];
}

/*
 * NSWindow answers GSAppKitDraggingEnter and _Update with a status (the
 * operation the view under the drag takes), and a drop with
 * GSAppKitDraggingFinished. data1 is the session we posted.
 */
- (void) postDragEvent: (NSEvent *)theEvent
{
  ws_connection_t *conn = [NextBSDServer connection];

  if (![NextBSDDragView serverDrags])
    {
      [super postDragEvent: theEvent];
      return;
    }
  switch ([theEvent subtype])
    {
    case GSAppKitDraggingStatus:
      ws_drag_status(conn, (uint32_t)[theEvent data1],
		     (uint32_t)[theEvent windowNumber],
		     ws_ops((NSDragOperation)[theEvent data2]), 0);
      break;
    case GSAppKitDraggingFinished:
      ws_drag_status(conn, (uint32_t)[theEvent data1],
		     (uint32_t)[theEvent windowNumber], WS_DRAG_OP_NONE,
		     WS_DRAG_STATUS_FINISHED);
      if (!isDragging)
	{
	  /* Another app's drag is over. */
	  destWindow = nil;
	  DESTROY(dragPasteboard);
	}
      break;
    default:
      break;
    }
  [[self _server] scheduleDispatch];
}

#else /* !WS_SERVER_DRAG */

- (void) takeDragEvent: (const ws_event_t *)event
{
}

#endif /* WS_SERVER_DRAG */

@end

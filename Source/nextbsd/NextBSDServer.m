/*
   NextBSDServer - display server for the NextBSD WindowServer

   Copyright (C) 2020 Free Software Foundation, Inc.
   Copyright (C) 2026 Joseph Maloney

   Structure adapted from the Wayland backend (WaylandServer.m) by
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

#include "config.h"
#include <AppKit/AppKitExceptions.h>
#include <AppKit/NSApplication.h>
#include <AppKit/NSBitmapImageRep.h>
#include <AppKit/NSGraphics.h>
#include <AppKit/NSGraphicsContext.h>
#include <AppKit/NSImage.h>
#include <AppKit/NSView.h>
#include <AppKit/DPSOperators.h>
#include <AppKit/NSEvent.h>
#include <AppKit/NSWindow.h>
#include <AppKit/NSMenu.h>
#include <AppKit/NSMenuView.h>
#include <Foundation/NSArray.h>
#include <Foundation/NSConnection.h>
#include <Foundation/NSDebug.h>
#include <Foundation/NSException.h>
#include <Foundation/NSMapTable.h>
#include <Foundation/NSNotification.h>
#include <Foundation/NSProcessInfo.h>
#include <Foundation/NSRunLoop.h>
#include <Foundation/NSTimer.h>
#include <Foundation/NSUserDefaults.h>
#include <Foundation/NSValue.h>

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include "nextbsd/NextBSDServer.h"
#include "nextbsd/NextBSDCairoShmSurface.h"

/* The connection, shared with the cairo surfaces. */
static ws_connection_t *sharedConnection = NULL;

static void
event_handler(ws_connection_t *c, const ws_event_t *event, void *context)
{
  NextBSDServer *srv = (NextBSDServer *)context;

  /* Never let an exception unwind through libWindowServerClient. */
  NS_DURING
    {
      [srv handleEvent: event];
    }
  NS_HANDLER
    {
      NSLog(@"NextBSD: exception while handling a WindowServer %s event: %@",
	    ws_event_name(event->hdr.type), localException);
    }
  NS_ENDHANDLER
}

/* Run loop modes the connection is watched in. */
static NSArray *
watchedModes(void)
{
  static NSArray *modes = nil;

  if (modes == nil)
    {
      modes = [[NSArray alloc] initWithObjects: NSDefaultRunLoopMode,
	NSConnectionReplyMode, NSModalPanelRunLoopMode,
	NSEventTrackingRunLoopMode, nil];
    }
  return modes;
}

@implementation NextBSDServer

/* Initialize AppKit backend */
+ (void) initializeBackend
{
  NSDebugLog(@"Initializing GNUstep NextBSD backend");
  [GSDisplayServer setDefaultServerClass: [NextBSDServer class]];
}

+ (ws_connection_t *) connection
{
  return sharedConnection;
}

- (ws_connection_t *) connection
{
  return conn;
}

- (NSDictionary *) windowServerAppCredentials
{
  if (conn == NULL)
    return nil;
  return [NSDictionary dictionaryWithObjectsAndKeys:
    [NSNumber numberWithUnsignedInt: ws_client_id(conn)], @"ClientID",
    [NSNumber numberWithUnsignedLongLong: ws_client_token(conn)], @"Token",
    nil];
}

- (id) initWithAttributes: (NSDictionary *)info
{
  NSString	 *name;
  NSRunLoop	 *loop;
  NSEnumerator	 *e;
  NSString	 *mode;
  NSUserDefaults *defs;
  NSNotificationCenter *nc;

  self = [super initWithAttributes: info];
  if (self == nil)
    return nil;

  name = [[NSProcessInfo processInfo] processName];
  conn = ws_connect([name UTF8String], 0);
  if (conn == NULL)
    {
      [NSException raise: NSWindowServerCommunicationException
		  format: @"Unable to connect to the NextBSD WindowServer: %s",
		   strerror(errno)];
    }
  sharedConnection = conn;
  screen = *ws_main_screen(conn);
  /* WindowServer draws the minimized windows; older servers leave
     that to libs-gui's miniwindows. */
  serverMinimizes = (ws_server_flags(conn) & WS_SERVER_MINIMIZE) != 0;
  windows = NSCreateMapTable(NSIntegerMapKeyCallBacks,
			     NSNonOwnedPointerMapValueCallBacks, 32);
  stack = [[NSMutableArray alloc] init];
  pointerScreen = NSMakePoint(-1, -1);

  defs = [NSUserDefaults standardUserDefaults];
  scrollMultiplier = [defs floatForKey: @"GSMouseScrollMultiplier"];
  if (scrollMultiplier < 0.0001f)
    scrollMultiplier = 1.0f;
  /* Precise (touchpad) scrolling arrives in pixels; NSScrollView scrolls
     by lines, 10 pixels by default. */
  scrollPixelsPerLine = [defs floatForKey: @"GSScrollPixelsPerLine"];
  if (scrollPixelsPerLine < 0.0001f)
    scrollPixelsPerLine = 10.0f;

  /* Watch the event socket from the run loop, like the X11 and Wayland
     servers do. NextBSD's main dispatch queue doesn't reliably wake
     NSRunLoop, so nothing here uses libdispatch. */
  loop = [NSRunLoop currentRunLoop];
  e = [watchedModes() objectEnumerator];
  while ((mode = [e nextObject]) != nil)
    {
      [loop addEvent: (void *)(intptr_t)ws_connection_fd(conn)
		type: ET_RDESC
	     watcher: (id<RunLoopEvents>)self
	     forMode: mode];
    }

  nc = [NSNotificationCenter defaultCenter];
  [nc addObserver: self
	 selector: @selector(_appWillBecomeActive:)
	     name: NSApplicationWillBecomeActiveNotification
	   object: nil];
  [nc addObserver: self
	 selector: @selector(_appDidResignActive:)
	     name: NSApplicationDidResignActiveNotification
	   object: nil];
  if (serverMinimizes)
    {
      [nc addObserver: self
	     selector: @selector(_appDidFinishLaunching:)
		 name: NSApplicationDidFinishLaunchingNotification
	       object: nil];
    }

  [self setupCursors];
  /* ws_connect may have queued events while waiting for its welcome. */
  [self scheduleDispatch];
  NSDebugLLog(@"NextBSD", @"connected to WindowServer as client %u, "
	      @"screen %ux%u", ws_client_id(conn), screen.width,
	      screen.height);
  return self;
}

- (void) closeServer
{
  NSEnumerator *e;
  NSString	*mode;
  NSRunLoop	*loop = [NSRunLoop currentRunLoop];

  if (conn != NULL)
    {
      e = [watchedModes() objectEnumerator];
      while ((mode = [e nextObject]) != nil)
	{
	  [loop removeEvent: (void *)(intptr_t)ws_connection_fd(conn)
		       type: ET_RDESC
		    forMode: mode
			all: YES];
	}
    }
  [super closeServer];
}

- (void) dealloc
{
  NSMapEnumerator  en;
  void		  *key;
  nextbsd_window_t *w;

  [[NSNotificationCenter defaultCenter] removeObserver: self];
  [previewTimer invalidate];
  previewTimer = nil;
  DESTROY(uploadedIcon);
  DESTROY(stack);
  if (windows != nil)
    {
      en = NSEnumerateMapTable(windows);
      while (NSNextMapEnumeratorPair(&en, &key, (void **)&w))
	{
	  [w->surface detach];
	  free(w);
	}
      NSEndMapTableEnumeration(&en);
      NSFreeMapTable(windows);
      windows = nil;
    }
  if (conn != NULL)
    {
      if (sharedConnection == conn)
	sharedConnection = NULL;
      ws_disconnect(conn);
      conn = NULL;
    }
  [super dealloc];
}

/* ---- the connection ---- */

- (void) receivedEvent: (void *)data
		  type: (RunLoopEventType)type
		 extra: (void *)extra
	       forMode: (NSString *)mode
{
  if (type == ET_RDESC)
    {
      [self dispatchEvents];
    }
}

- (void) dispatchEvents
{
  int n;

  dispatchScheduled = NO;
  if (conn == NULL)
    return;
  n = ws_dispatch(conn, event_handler, self);
  if (n < 0)
    {
      NSLog(@"NextBSD: lost the connection to WindowServer (%s)",
	    strerror(errno));
      exit(EXIT_FAILURE);
    }
}

- (void) scheduleDispatch
{
  if (dispatchScheduled || conn == NULL || !ws_pending(conn))
    return;
  dispatchScheduled = YES;
  [self performSelector: @selector(dispatchEvents)
	     withObject: nil
	     afterDelay: 0.0
		inModes: watchedModes()];
}

/* ---- activation requested by the app ---- */

- (void) _appWillBecomeActive: (NSNotification *)n
{
  if (!serverActivating && conn != NULL)
    {
      ws_activate(conn);
    }
}

- (void) _appDidResignActive: (NSNotification *)n
{
  if (!serverDeactivating && conn != NULL)
    {
      ws_deactivate(conn);
    }
}

- (void) _appDidFinishLaunching: (NSNotification *)n
{
  /* The icon WindowServer badges the tiles of minimized windows with. */
  [self uploadAppIconIfChanged];
}

/* ---- helpers ---- */

- (nextbsd_window_t *) windowWithNumber: (int)win
{
  if (windows == nil || win <= 0)
    return NULL;
  return NSMapGet(windows, (void *)(intptr_t)win);
}

- (CGFloat) screenHeight
{
  return (CGFloat)screen.height;
}

- (ws_rect_t) wsRectFromNSRect: (NSRect)r
{
  ws_rect_t w;

  w.x = (int32_t)NSMinX(r);
  w.width = (int32_t)NSWidth(r);
  w.height = (int32_t)NSHeight(r);
  w.y = (int32_t)([self screenHeight] - NSMaxY(r));
  if (w.width < 1)
    w.width = 1;
  if (w.height < 1)
    w.height = 1;
  return w;
}

- (NSRect) nsRectFromWSRect: (ws_rect_t)r
{
  return NSMakeRect(r.x, [self screenHeight] - r.y - r.height,
		    r.width, r.height);
}

/* WindowServer flags for a window, from what libs-gui knows about it. */
- (void) updateFlags: (nextbsd_window_t *)w
{
  static Class	menuPanelClass = Nil;
  NSWindow	*nswin = GSWindowWithNumber(w->number);
  uint32_t	 flags = 0;

  if (menuPanelClass == Nil)
    menuPanelClass = NSClassFromString(@"NSMenuPanel");

  /* Menus never take the key window from the app's document windows. */
  if (w->level == NSMainMenuWindowLevel
      || w->level == NSSubmenuWindowLevel
      || w->level == NSPopUpMenuWindowLevel
      || (menuPanelClass != Nil && [nswin isKindOfClass: menuPanelClass])
      || (nswin != nil && [nswin canBecomeKeyWindow] == NO))
    {
      flags |= WS_WINDOW_NO_KEY;
    }
  if (w->ignoresMouse)
    flags |= WS_WINDOW_IGNORES_MOUSE;
  /* App icons and miniwindows: WindowServer finds them a free place. */
  if (nswin != nil
      && ([nswin styleMask] & (NSIconWindowMask | NSMiniWindowMask)) != 0)
    flags |= WS_WINDOW_ICON;
  if (flags != w->flags)
    {
      w->flags = flags;
      ws_window_set_flags(conn, w->number, flags);
    }
}

/* Tell the NSWindow its frame changed (GSAppKitWindowMoved/Resized). */
- (void) _notifyFrame: (nextbsd_window_t *)w post: (BOOL)post
{
  NSWindow *nswin = GSWindowWithNumber(w->number);
  NSRect    old;
  NSEvent  *ev = nil;

  if (nswin == nil)
    return;
  old = [nswin frame];
  if (!NSEqualSizes(old.size, w->frame.size))
    {
      /* A resize event also moves the origin. */
      ev = [NSEvent otherEventWithType: NSAppKitDefined
			      location: w->frame.origin
			 modifierFlags: 0
			     timestamp: 0
			  windowNumber: w->number
			       context: GSCurrentContext()
			       subtype: GSAppKitWindowResized
				 data1: NSWidth(w->frame)
				 data2: NSHeight(w->frame)];
    }
  else if (!NSEqualPoints(old.origin, w->frame.origin))
    {
      ev = [NSEvent otherEventWithType: NSAppKitDefined
			      location: NSZeroPoint
			 modifierFlags: 0
			     timestamp: 0
			  windowNumber: w->number
			       context: GSCurrentContext()
			       subtype: GSAppKitWindowMoved
				 data1: NSMinX(w->frame)
				 data2: NSMinY(w->frame)];
    }
  if (ev == nil)
    return;
  if (post)
    [self postEvent: ev atStart: NO];
  else
    [nswin sendEvent: ev];
}

/* ---- screens ---- */

- (BOOL) handlesWindowDecorations
{
  /* libs-gui draws title bars and resize bars itself. */
  return NO;
}

- (void) restrictWindow: (int)win toImage: (NSImage *)image
{
}

- (NSRect) boundsForScreen: (int)aScreen
{
  return NSMakeRect(0, 0, screen.width, screen.height);
}

/* libs-gui scales the whole UI by this resolution / 72 when GSScaleFactor
   isn't set, so reporting the display's physical DPI made everything about
   1.4 times too big. Report 72, as the X11 backend does (it keeps
   GSDisplayServer's default); HiDPI scaling comes from GSScaleFactor. */
- (NSSize) resolutionForScreen: (int)aScreen
{
  return NSMakeSize(72, 72);
}

- (NSWindowDepth) windowDepthForScreen: (int)aScreen
{
  return (_GSRGBBitValue | 8);
}

- (const NSWindowDepth *) availableDepthsForScreen: (int)aScreen
{
  NSWindowDepth *depths;

  depths = NSZoneMalloc(NSDefaultMallocZone(), sizeof(NSWindowDepth) * 2);
  depths[0] = (_GSRGBBitValue | 8);
  depths[1] = 0;
  return depths;
}

- (NSArray *) screenList
{
  return [NSArray arrayWithObject: [NSNumber numberWithInt: screen.screen_id]];
}

- (void) setScreenInfo: (const ws_screen_info_t *)info
{
  screen = *info;
}

- (void *) serverDevice
{
  return conn;
}

/* The native window: WindowServer's window id, which is also the
   window's number here. As the X11 backend answers with the X window,
   -[NSWindow windowRef] and NSConvertWindowNumberToGlobal() then name
   the window the way other processes see it: the Dock looks up the
   window GSIconManager's -setWindow:appProcessId: names in
   WindowServer's window list, and GSDragView compares it with what
   -findWindowAt:windowRef:excluding: answers. 0 if there's no such
   window. */
- (void *) windowDevice: (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  return w != NULL ? (void *)(intptr_t)w->number : NULL;
}

- (void) beep
{
  NSDebugLLog(@"NextBSD", @"beep");
}

@end

/* ----------------------------------------------------------------------- */

@implementation NextBSDServer (WindowOps)

- (int) window: (NSRect)frame
	      : (NSBackingStoreType)type
	      : (unsigned int)style
	      : (int)aScreen
{
  nextbsd_window_t *w;
  ws_rect_t	    r;
  uint32_t	    number;

  if (NSWidth(frame) < 1)
    frame.size.width = 1;
  if (NSHeight(frame) < 1)
    frame.size.height = 1;
  r = [self wsRectFromNSRect: frame];
  number = ws_window_create(conn, &r, NSNormalWindowLevel, 0, "");
  if (number == 0)
    {
      NSLog(@"NextBSD: WindowServer didn't create a window: %s",
	    strerror(errno));
      return 0;
    }
  w = calloc(1, sizeof(*w));
  w->number = (int)number;
  w->frame = frame;
  w->level = NSNormalWindowLevel;
  w->type = type;
  NSMapInsert(windows, (void *)(intptr_t)w->number, w);
  [self _setWindowOwnedByServer: w->number];
  NSDebugLLog(@"NextBSD", @"window %d created: %@", w->number,
	      NSStringFromRect(frame));
  return w->number;
}

- (void) termwindow: (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w == NULL)
    return;
  [w->surface detach];
  w->surface = nil;
  ws_window_destroy(conn, w->number);
  NSMapRemove(windows, (void *)(intptr_t)win);
  [self _stackRemove: win];
  if (pointerWindow == win)
    pointerWindow = 0;
  free(w);
}

- (int) nativeWindow: (void *)winref
		    : (NSRect *)frame
		    : (NSBackingStoreType *)type
		    : (unsigned int *)style
		    : (int *)aScreen
{
  return 0;
}

- (void) stylewindow: (unsigned int)style : (int)win
{
}

- (void) windowbacking: (NSBackingStoreType)type : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w != NULL)
    w->type = type;
}

- (void) titlewindow: (NSString *)title : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w == NULL)
    return;
  ws_window_set_title(conn, w->number, title ? [title UTF8String] : "");
}

- (void) miniwindow: (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w == NULL)
    return;
  /* With GSSuppressAppIcon, hiding the app miniaturizes all its
     windows, the app icon window too. That one is never on screen
     then (NSIconWindow doesn't order itself in or out), so it gets no
     tile, which nothing could take away again; the tiles of the other
     windows stand for the hidden app. */
  if (serverMinimizes && NSApp != nil
      && GSWindowWithNumber(win) == [NSApp iconWindow])
    return;
  w->miniaturized = YES;
  w->visible = NO;
  [self _stackRemove: w->number];
  if (serverMinimizes)
    {
      /* WindowServer orders the window out and shows a live tile of it,
	 badged with the app icon, until the app orders it in again. */
      [self uploadAppIconIfChanged];
      ws_window_minimize(conn, w->number);
      [self _startPreviewTimer];
    }
  else
    {
      /* The app draws its own miniwindow; hide the real one. */
      ws_window_order(conn, w->number, WS_ORDER_OUT, 0);
    }
}

- (BOOL) hideApplication: (int)win
{
  /* libs-gui orders the windows out itself; WindowServer hears about it
     through the ordering and the deactivation. */
  return NO;
}

- (BOOL) appOwnsMiniwindow
{
  /* With NO, libs-gui makes no miniwindow and leaves minimizing to
     -miniwindow:. */
  return serverMinimizes ? NO : YES;
}

- (void) setWindowdevice: (int)win forContext: (NSGraphicsContext *)ctxt
{
  nextbsd_window_t *w = [self windowWithNumber: win];
  int		    height;

  if (w == NULL)
    return;
  height = (int)NSHeight(w->frame);
  if (height < 1)
    height = 1;
  GSSetDevice(ctxt, w, 0, height);
  DPSinitmatrix(ctxt);
  DPSinitclip(ctxt);
}

- (void) orderwindow: (int)op : (int)otherWin : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w == NULL)
    return;
  if (op == NSWindowOut)
    {
      w->visible = NO;
      [self _stackRemove: w->number];
      ws_window_order(conn, w->number, WS_ORDER_OUT, 0);
      return;
    }
  [self updateFlags: w];
  [self _keepMenuOnScreen: w];
  [self _stackPlace: w op: op relativeTo: otherWin];
  w->visible = YES;
  w->miniaturized = NO;
  ws_window_order(conn, w->number,
		  op == NSWindowBelow ? WS_ORDER_BELOW : WS_ORDER_ABOVE,
		  otherWin > 0 ? (uint32_t)otherWin : 0);
  [self _focusModalWindow: w];
}

/*
 * -[NSApplication beginModalSessionForWindow:] asks the panel to become
 * key before ordering it in, and -makeKeyWindow does nothing for a
 * window that isn't visible yet. Under X11 the window manager focuses
 * the newly mapped panel and libs-gui makes it key on the FocusIn; do
 * what the window manager does: when the app's modal window (an alert,
 * a modal panel or a sheet) comes on screen without being key, tell it
 * it has the focus. Closing it gives the key window back through
 * libs-gui's -_lossOfKeyOrMainWindow and -setinputfocus:.
 */
- (void) _focusModalWindow: (nextbsd_window_t *)w
{
  NSWindow *nswin;

  if (NSApp == nil || [NSApp isActive] == NO
      || (w->flags & WS_WINDOW_NO_KEY))
    return;
  nswin = GSWindowWithNumber(w->number);
  if (nswin == nil || nswin != [NSApp modalWindow]
      || [nswin isKeyWindow] || [nswin canBecomeKeyWindow] == NO)
    return;
  [self _postFocusIn: w->number];
}

- (void) _postFocusIn: (int)win
{
  NSEvent *e;

  e = [NSEvent otherEventWithType: NSAppKitDefined
			 location: NSZeroPoint
		    modifierFlags: 0
			timestamp: 0
		     windowNumber: win
			  context: GSCurrentContext()
			  subtype: GSAppKitWindowFocusIn
			    data1: 0
			    data2: 0];
  [self postEvent: e atStart: NO];
}

/*
 * Menus (submenus, pop-up and context menus) are placed where libs-gui
 * computes, centred on the pointer or to the right of their supermenu,
 * which can run off the right or bottom edge of the screen; under X11
 * the window manager keeps them on screen. Shift a menu window so it is
 * fully on screen, along each axis it fits on, and tell the NSWindow
 * where it went. A submenu that would run off the right edge opens on
 * the left of its supermenu instead, so it doesn't cover it. A menu
 * taller than the screen is left alone vertically, so libs-gui can
 * still scroll it.
 */
- (BOOL) _isMenuLevel: (int)level
{
  return level == NSSubmenuWindowLevel || level == NSPopUpMenuWindowLevel;
}

/* The frame of the menu window a submenu window opens from, or
   NSZeroRect. The supermenu may still be on its way on screen (libs-gui
   can show the submenu while it orders the supermenu in), so this asks
   our own record of it, which has its final frame. */
- (NSRect) _supermenuFrame: (int)win
{
  NSWindow	   *nswin = GSWindowWithNumber(win);
  NSView	   *view = [nswin contentView];
  NSMenu	   *menu, *sup;
  nextbsd_window_t *s;

  /* A menu shown transiently (a context menu and its submenus) has
     its menu view inside the transient window's content view. */
  if (![view isKindOfClass: [NSMenuView class]]
      && [[view subviews] count] == 1)
    view = [[view subviews] objectAtIndex: 0];
  if (![view isKindOfClass: [NSMenuView class]])
    return NSZeroRect;
  menu = [(NSMenuView *)view menu];
  sup = [menu supermenu];
  if (sup == nil || [menu isTornOff])
    return NSZeroRect;
  s = [self windowWithNumber: [[[sup menuRepresentation] window] windowNumber]];
  if (s == NULL || s->number == win)
    return NSZeroRect;
  return s->frame;
}

- (NSRect) _menuFrameOnScreen: (NSRect)frame window: (nextbsd_window_t *)w
{
  CGFloat sw = screen.width, sh = screen.height;
  NSRect  sup;

  if (![self _isMenuLevel: w->level] || sw <= 0 || sh <= 0)
    return frame;
  if (NSWidth(frame) <= sw)
    {
      if (NSMaxX(frame) > sw)
	{
	  sup = [self _supermenuFrame: w->number];
	  if (!NSIsEmptyRect(sup) && NSMinX(frame) >= NSMidX(sup)
	      && NSMinX(sup) - NSWidth(frame) >= 0)
	    frame.origin.x = NSMinX(sup) - NSWidth(frame);
	  else
	    frame.origin.x = sw - NSWidth(frame);
	}
      if (NSMinX(frame) < 0)
	frame.origin.x = 0;
    }
  if (NSHeight(frame) <= sh)
    {
      if (NSMinY(frame) < 0)
	frame.origin.y = 0;
      if (NSMaxY(frame) > sh)
	frame.origin.y = sh - NSHeight(frame);
    }
  return frame;
}

- (void) _keepMenuOnScreen: (nextbsd_window_t *)w
{
  NSRect    frame = [self _menuFrameOnScreen: w->frame window: w];
  ws_rect_t r;

  if (NSEqualRects(frame, w->frame))
    return;
  NSDebugLLog(@"NextBSD", @"menu window %d kept on screen: %@ -> %@",
	      w->number, NSStringFromRect(w->frame), NSStringFromRect(frame));
  w->frame = frame;
  r = [self wsRectFromNSRect: frame];
  ws_window_set_frame(conn, w->number, &r);
  [self _notifyFrame: w post: NO];
}

- (void) movewindow: (NSPoint)loc : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];
  NSRect	    frame;

  if (w == NULL)
    return;
  frame = w->frame;
  frame.origin = loc;
  [self placewindow: frame : win];
}

- (void) placewindow: (NSRect)rect : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];
  ws_rect_t	    r;

  if (w == NULL)
    return;
  NSDebugLLog(@"NextBSD", @"placewindow %d: %@", win, NSStringFromRect(rect));
  rect = [self _menuFrameOnScreen: rect window: w];
  if (!NSEqualRects(rect, w->frame))
    {
      w->frame = rect;
      r = [self wsRectFromNSRect: rect];
      ws_window_set_frame(conn, w->number, &r);
    }
  /* WindowServer doesn't answer a frame change, so tell the window now. */
  [self _notifyFrame: w post: NO];
}

- (NSRect) windowbounds: (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  return w != NULL ? w->frame : NSZeroRect;
}

- (void) setwindowlevel: (int)level : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w == NULL)
    return;
  if (w->level != level)
    {
      w->level = level;
      /* libs-gui levels are WindowServer levels. */
      ws_window_set_level(conn, w->number, level);
      if (w->visible)
	[self _stackPlace: w op: NSWindowAbove relativeTo: 0];
    }
  [self updateFlags: w];
}

- (int) windowlevel: (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  return w != NULL ? w->level : 0;
}

/*
 * This app's visible windows, bottom to top, kept the way WindowServer
 * stacks them: by level, then by order within a level.
 */
- (void) _stackRemove: (int)win
{
  NSUInteger i = [stack count];

  while (i-- > 0)
    {
      if ([[stack objectAtIndex: i] intValue] == win)
	[stack removeObjectAtIndex: i];
    }
}

- (int) _stackLevelAt: (NSUInteger)i
{
  nextbsd_window_t *o = [self windowWithNumber:
				[[stack objectAtIndex: i] intValue]];

  return o != NULL ? o->level : 0;
}

- (void) _stackPlace: (nextbsd_window_t *)w op: (int)op relativeTo: (int)rel
{
  nextbsd_window_t *r = [self windowWithNumber: rel];
  NSNumber	   *n = [NSNumber numberWithInt: w->number];
  NSUInteger	    i, count;

  [self _stackRemove: w->number];
  count = [stack count];
  if (r != NULL && r != w && r->visible && r->level == w->level)
    {
      i = [stack indexOfObject: [NSNumber numberWithInt: rel]];
      if (i != NSNotFound)
	{
	  [stack insertObject: n atIndex: op == NSWindowBelow ? i : i + 1];
	  return;
	}
    }
  if (op == NSWindowBelow)
    {
      /* below the lowest window whose level is >= ours */
      for (i = 0; i < count; i++)
	if ([self _stackLevelAt: i] >= w->level)
	  break;
      [stack insertObject: n atIndex: i];
    }
  else
    {
      /* above the highest window whose level is <= ours */
      for (i = count; i > 0; i--)
	if ([self _stackLevelAt: i - 1] <= w->level)
	  break;
      [stack insertObject: n atIndex: i];
    }
}

/* Front to back, like the X11 server's list. */
- (NSArray *) windowlist
{
  return [[stack reverseObjectEnumerator] allObjects];
}

- (int) findWindowAt: (NSPoint)screenLocation
	   windowRef: (int *)windowRef
	   excluding: (int)win
{
  NSUInteger i = [stack count];

  while (i-- > 0)
    {
      int		number = [[stack objectAtIndex: i] intValue];
      nextbsd_window_t *w = [self windowWithNumber: number];

      if (w == NULL || number == win || w->ignoresMouse)
	continue;
      if (NSPointInRect(screenLocation, w->frame))
	{
	  if (windowRef != NULL)
	    *windowRef = number;
	  return number;
	}
    }
  if (windowRef != NULL)
    *windowRef = 0;
  return 0;
}

- (int) windowdepth: (int)win
{
  return 0;
}

- (void) setmaxsize: (NSSize)size : (int)win
{
}

- (void) setminsize: (NSSize)size : (int)win
{
}

- (void) setresizeincrements: (NSSize)size : (int)win
{
}

- (void) flushwindowrect: (NSRect)rect : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];
  NSRect	    r;

  if (w == NULL || w->surface == nil)
    return;
  /* Window base coordinates -> top-left window pixels. */
  r.origin.x = NSMinX(rect);
  r.origin.y = NSHeight(w->frame) - NSMaxY(rect);
  r.size = rect.size;
  [w->surface handleExposeRect: r];
}

- (void) styleoffsets: (float *)l : (float *)r : (float *)t : (float *)b
		     : (unsigned int)style
{
  /* No server decorations. */
  *l = *r = *t = *b = 0.0;
}

- (void) docedited: (int)edited : (int)win
{
}

- (void) setinputstate: (int)state : (int)win
{
  /* libs-gui draws the title bar state itself. */
}

- (void) setalpha: (float)alpha : (int)win
{
}

- (void) setShadow: (BOOL)hasShadow : (int)win
{
}

- (void) setParentWindow: (int)parentWin forChildWindow: (int)childWin
{
}

- (void) setIgnoreMouse: (BOOL)ignoreMouse : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w == NULL)
    return;
  w->ignoresMouse = ignoreMouse;
  [self updateFlags: w];
}

@end

/* ----------------------------------------------------------------------- */

@implementation NextBSDServer (Minimize)

/* The app icon as premultiplied ARGB8888, size x size, drawn with cairo
   into a bitmap (CairoBitmapSurface). */
- (void) _uploadAppIcon: (NSImage *)icon
{
  const int	     size = 64;
  NSBitmapImageRep  *rep;
  NSGraphicsContext *ctx;
  NSGraphicsContext *old;
  unsigned char	    *p;
  uint32_t	    *argb;
  int		     i;

  rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes: NULL
						 pixelsWide: size
						 pixelsHigh: size
					      bitsPerSample: 8
					    samplesPerPixel: 4
						   hasAlpha: YES
						   isPlanar: NO
					     colorSpaceName: NSDeviceRGBColorSpace
						bytesPerRow: size * 4
					       bitsPerPixel: 32];
  if (rep == nil)
    return;
  memset([rep bitmapData], 0, size * size * 4);
  ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep: rep];
  if (ctx == nil)
    {
      RELEASE(rep);
      return;
    }
  old = [NSGraphicsContext currentContext];
  [NSGraphicsContext setCurrentContext: ctx];
  NS_DURING
    {
      [icon drawInRect: NSMakeRect(0, 0, size, size)
	      fromRect: NSZeroRect
	     operation: NSCompositeSourceOver
	      fraction: 1.0];
      [ctx flushGraphics];
    }
  NS_HANDLER
    {
      NSLog(@"NextBSD: can't draw the app icon for WindowServer: %@",
	    localException);
    }
  NS_ENDHANDLER
  [NSGraphicsContext setCurrentContext: old];

  /* The bitmap is RGBA, premultiplied (bitmapFormat 0). */
  p = [rep bitmapData];
  argb = malloc(size * size * 4);
  if (argb != NULL)
    {
      for (i = 0; i < size * size; i++, p += 4)
	{
	  argb[i] = ((uint32_t)p[3] << 24) | ((uint32_t)p[0] << 16)
	    | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
	}
      if (ws_set_app_icon(conn, size, size, argb, size * 4) < 0)
	NSDebugLLog(@"NextBSD", @"ws_set_app_icon: %s", strerror(errno));
      free(argb);
    }
  RELEASE(rep);
}

- (void) uploadAppIconIfChanged
{
  NSImage *icon;

  if (!serverMinimizes || conn == NULL || NSApp == nil)
    return;
  /* -setApplicationIconImage: always installs a new image object. */
  icon = [NSApp applicationIconImage];
  if (icon == nil || icon == uploadedIcon)
    return;
  ASSIGN(uploadedIcon, icon);
  [self _uploadAppIcon: icon];
}

- (void) _startPreviewTimer
{
  NSRunLoop    *loop = [NSRunLoop currentRunLoop];
  NSEnumerator *e;
  NSString     *mode;

  if (previewTimer != nil)
    return;
  previewTimer = [NSTimer timerWithTimeInterval: 0.25
					 target: self
				       selector: @selector(_drawMinimized:)
				       userInfo: nil
					repeats: YES];
  e = [watchedModes() objectEnumerator];
  while ((mode = [e nextObject]) != nil)
    [loop addTimer: previewTimer forMode: mode];
}

/*
 * Keep the tiles live. libs-gui stops displaying a window once it is
 * miniaturized (-[NSWindow displayIfNeeded] returns early), so a few
 * times a second the backend displays the views of minimized windows
 * that need it and flushes them; WindowServer redraws the tile from
 * every commit. The timer stops when no window is minimized, and also
 * picks up a changed app icon while tiles show it.
 */
- (void) _drawMinimized: (NSTimer *)timer
{
  NSMutableArray   *numbers = [NSMutableArray array];
  NSMapEnumerator   en;
  void		   *key;
  nextbsd_window_t *w;
  NSEnumerator	   *e;
  NSNumber	   *n;

  /* Drawing can create windows (image caches), so don't draw while
     enumerating the map. */
  en = NSEnumerateMapTable(windows);
  while (NSNextMapEnumeratorPair(&en, &key, (void **)&w))
    {
      if (w->miniaturized && !w->visible)
	[numbers addObject: [NSNumber numberWithInt: w->number]];
    }
  NSEndMapTableEnumeration(&en);
  if ([numbers count] == 0)
    {
      [previewTimer invalidate];
      previewTimer = nil;
      return;
    }
  [self uploadAppIconIfChanged];
  e = [numbers objectEnumerator];
  while ((n = [e nextObject]) != nil)
    {
      NSWindow *nswin = GSWindowWithNumber([n intValue]);
      NSView   *top;

      if (nswin == nil || ![nswin isMiniaturized]
	  || ![nswin viewsNeedDisplay])
	continue;
      /* The frame view: the content view and the title bar. */
      top = [[nswin contentView] superview];
      if (top == nil)
	top = [nswin contentView];
      NS_DURING
	{
	  [top displayIfNeeded];
	  [nswin flushWindow];
	}
      NS_HANDLER
	{
	  NSLog(@"NextBSD: exception drawing minimized window %d: %@",
		[n intValue], localException);
	}
      NS_ENDHANDLER
    }
}

@end

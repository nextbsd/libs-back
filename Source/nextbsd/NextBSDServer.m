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
#include <AppKit/NSInterfaceStyle.h>
#include <AppKit/NSView.h>
#include <AppKit/DPSOperators.h>
#include <AppKit/NSEvent.h>
#include <AppKit/NSWindow.h>
#include <AppKit/NSMenu.h>
#include <AppKit/NSMenuView.h>
#include <AppKit/NSPanel.h>
#include <AppKit/NSScreen.h>
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
#include <GNUstepGUI/GSTheme.h>

#include <errno.h>
#include <stdlib.h>
#include <string.h>

#include <objc/runtime.h>

#include "nextbsd/NextBSDServer.h"
#include "nextbsd/NextBSDCairoShmSurface.h"
#include "nextbsd/NextBSDDragView.h"

/*
 * A NextBSD desktop setting: the user's choice (the key in the user's
 * defaults, from Workspace Preferences), else the active theme's default
 * (the key at the top of its Info.plist), else the built-in one. The
 * Dock position and the menu style are kept per window mode
 * (NBWindowMode): the user's NBModeSettings[mode] (in stacking, a plain
 * user key from before counts too), the theme's NBModeDefaults[mode],
 * the theme's plain key, the built-in one. This is the lookup in
 * nextbsd-theme's NBDesktopSettings.h; keep them in step.
 */
static NSString *
validSetting(id value, NSArray *allowed)
{
  if ([value isKindOfClass: [NSString class]]
      && [allowed containsObject: value])
    return value;
  return nil;
}

static BOOL
settingIsPerMode(NSString *key)
{
  return [key isEqual: @"NBDockPosition"] || [key isEqual: @"NBMenuStyle"];
}

/* modes[mode][key], when both are dictionaries. */
static id
modeValue(id modes, NSString *mode, NSString *key)
{
  id entry;

  if (![modes isKindOfClass: [NSDictionary class]])
    return nil;
  entry = [modes objectForKey: mode];
  if (![entry isKindOfClass: [NSDictionary class]])
    return nil;
  return [entry objectForKey: key];
}

NSString *
NextBSDDesktopUserSetting(NSString *key, NSString *mode, NSArray *allowed)
{
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  NSString	 *value;

  if (!settingIsPerMode(key))
    return validSetting([defs objectForKey: key], allowed);
  value = validSetting(modeValue([defs objectForKey: @"NBModeSettings"],
				 mode, key), allowed);
  if (value == nil && [mode isEqual: @"stacking"])
    value = validSetting([defs objectForKey: key], allowed);
  return value;
}

NSString *
NextBSDWindowMode(void)
{
  static NSArray *modes = nil;
  NSString	 *value;

  if (modes == nil)
    modes = [[NSArray alloc] initWithObjects: @"stacking", @"tiling", nil];
  value = NextBSDDesktopUserSetting(@"NBWindowMode", nil, modes);
  if (value == nil)
    value = validSetting([[[GSTheme theme] infoDictionary]
			   objectForKey: @"NBWindowMode"], modes);
  return value != nil ? value : @"stacking";
}

NSString *
NextBSDDesktopSetting(NSString *key, NSArray *allowed, NSString *builtin)
{
  NSString     *mode = settingIsPerMode(key) ? NextBSDWindowMode() : nil;
  NSDictionary *info;
  NSString     *value;

  value = NextBSDDesktopUserSetting(key, mode, allowed);
  if (value != nil)
    return value;
  info = [[GSTheme theme] infoDictionary];
  if (mode != nil)
    value = validSetting(modeValue([info objectForKey: @"NBModeDefaults"],
				   mode, key), allowed);
  if (value == nil)
    value = validSetting([info objectForKey: key], allowed);
  return value != nil ? value : builtin;
}

/* The minimize style: "nextstep" (libs-gui draws miniwindows), "previews"
   (WindowServer draws tiles) or "dock" (the tiles go to the Dock). */
static NSString *
minimizeStyle(void)
{
  static NSArray *styles = nil;

  if (styles == nil)
    styles = [[NSArray alloc] initWithObjects:
			    @"nextstep", @"previews", @"dock", nil];
  /* Pick up a change Workspace Preferences just saved. */
  [[NSUserDefaults standardUserDefaults] synchronize];
  return NextBSDDesktopSetting(@"NBMinimizeStyle", styles, @"dock");
}

#ifdef WS_SERVER_MINIMIZE_WHERE
/* Where WindowServer puts a minimized window: "dock" into the Dock (the
   bottom row while no Dock is connected), the other styles onto the
   bottom row. Servers without WS_SERVER_MINIMIZE_WHERE (and builds
   against their headers) leave it to their MinimizeIntoDock default. */
static uint32_t
minimizeWhere(void)
{
  return [minimizeStyle() isEqualToString: @"dock"]
    ? WS_MINIMIZE_INTO_DOCK : WS_MINIMIZE_BOTTOM_ROW;
}
#endif

/*
 * NSScreen's visibleFrame. libs-gui works it out in -[NSScreen
 * visibleFrame] from the screen's frame alone (taking off a Mac menu
 * bar); there is no GSDisplayServer method for it that a backend could
 * answer, so the Dock's strip never came off. Without changing libs-gui,
 * the backend wraps that one method when WindowServer reports a usable
 * area: the wrapper keeps libs-gui's answer and intersects it with the
 * current server's -visibleFrameForScreen:. Everything in libs-gui that
 * uses visibleFrame (main menu placement, -center, cascading,
 * -constrainFrameRect:toScreen:, zooming, saved frames) then follows it.
 */
static NSRect (*libsGuiVisibleFrame)(id, SEL) = NULL;

static NSRect
nextbsdVisibleFrame(id scr, SEL cmd)
{
  NSRect	   vis = libsGuiVisibleFrame(scr, cmd);
  GSDisplayServer *srv = GSCurrentServer();
  NSRect	   usable;

  if (srv == nil || ![srv respondsToSelector: @selector(visibleFrameForScreen:)])
    return vis;
  usable = [(NextBSDServer *)srv visibleFrameForScreen: [scr screenNumber]];
  if (NSIsEmptyRect(usable))
    return vis;
  usable = NSIntersectionRect(vis, usable);
  return NSIsEmptyRect(usable) ? vis : usable;
}

static void
wrapVisibleFrame(void)
{
  Method m;

  if (libsGuiVisibleFrame != NULL)
    return;
  m = class_getInstanceMethod([NSScreen class], @selector(visibleFrame));
  if (m == NULL)
    return;
  libsGuiVisibleFrame = (NSRect (*)(id, SEL))method_getImplementation(m);
  method_setImplementation(m, (IMP)nextbsdVisibleFrame);
}

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

- (BOOL) setWindowServerSettings: (NSDictionary *)settings
{
#ifdef WS_SERVER_SETTINGS
  NSEnumerator *e;
  NSString     *key;
  ws_setting_t *list;
  unsigned	n = 0;
  char		failed[64] = "";
  int		r;

  if (conn == NULL || [settings count] == 0
      || (ws_server_flags(conn) & WS_SERVER_SETTINGS) == 0)
    return NO;
  list = calloc([settings count], sizeof(*list));
  if (list == NULL)
    return NO;
  e = [settings keyEnumerator];
  while ((key = [e nextObject]) != nil)
    {
      id value = [settings objectForKey: key];

      if (![key isKindOfClass: [NSString class]])
	continue;
      list[n].key = [key UTF8String];
      if (value == nil || value == [NSNull null])
	{
	  list[n].type = WS_SETTING_DEFAULT;
	  list[n].value = "";
	}
      else
	{
	  /* WindowServer parses a string for any key. */
	  list[n].type = WS_SETTING_STRING;
	  list[n].value = [[value description] UTF8String];
	}
      n++;
    }
  r = n > 0 ? ws_set_settings(conn, 0, list, n, failed, sizeof(failed)) : -1;
  free(list);
  if (r < 0 && n > 0)
    NSLog(@"NextBSD: WindowServer refused the settings%s%s: %s",
	  failed[0] != '\0' ? " at " : "", failed, strerror(errno));
  [self scheduleDispatch];
  return r == 0;
#else
  return NO;
#endif
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
#ifdef WS_SERVER_USABLE_AREA
  /* The screen minus the Dock's strip, as NSScreen's visibleFrame. */
  haveUsableArea = ws_usable_area(conn, &usable) == 0;
  if (haveUsableArea)
    wrapVisibleFrame();
#endif
  /* WindowServer draws the minimized windows; older servers leave
     that to libs-gui's miniwindows. */
  serverMinimizes = (ws_server_flags(conn) & WS_SERVER_MINIMIZE) != 0;
#ifdef WS_SERVER_POINTER_GRAB
  /* A click outside the app closes its open menu (-_updatePopupGrab). */
  pointerGrabs = (ws_server_flags(conn) & WS_SERVER_POINTER_GRAB) != 0;
#endif
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
  /* The NBMenuStyle desktop setting chooses libs-gui's menu style, and
     changes it live (NextBSDServer+MenuStyle.m). */
  reportedMenuBar = -1;
  [self _setUpMenuStyle];
  /* Tiles aren't saved as the windows' frames. */
  [self _setUpTiledFrames];

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
  [self _tearDownMenuStyle];
  [previewTimer invalidate];
  previewTimer = nil;
  DESTROY(uploadedIcon);
  DESTROY(tiledFrames);
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
  /* A screen change comes as screen-changed, usable-area and the
     window-frame events of the windows WindowServer moved; tell the
     windows and the app once they're all in. */
  if (screenParamsPending)
    {
      [self _notifyAllFrames];
      [self _postScreenParameters];
    }
}

/*
 * After a screen change, tell every NSWindow its frame. Windows without
 * a parent go first: libs-gui moves a window's child windows with it
 * (an icon window on the Dock), and a child told its own new frame
 * first would then move a second time. A child the parent moved is
 * placed where libs-gui puts it (-placewindow::), so it stays with its
 * parent, and has nothing left to hear.
 */
- (void) _notifyAllFrames
{
  NSMapEnumerator   e;
  void		   *key;
  nextbsd_window_t *w;
  int		    pass;

  for (pass = 0; pass < 2; pass++)
    {
      e = NSEnumerateMapTable(windows);
      while (NSNextMapEnumeratorPair(&e, &key, (void **)&w))
	{
	  NSWindow *nswin = GSWindowWithNumber(w->number);

	  if ((pass == 0) == ([nswin parentWindow] == nil))
	    [self _notifyFrame: w post: NO];
	}
      NSEndMapTableEnumeration(&e);
    }
}

/*
 * The screen changed: NSScreen reads the new frame,
 * and the app hears NSApplicationDidChangeScreenParametersNotification.
 * Every window's frame is already right (-_screenChanged:), but
 * -[NSWindow applicationDidChangeScreenParameters:] moves a window that
 * isn't inside the new screen once more by the change in height, to
 * keep its top where it was, which WindowServer's top-left coordinates
 * already did. -placewindow:: leaves out that second move while the
 * notification goes out.
 */
- (void) _postScreenParameters
{
  screenParamsPending = NO;
  [NSScreen resetScreens];
  postingHeightDelta = pendingHeightDelta;
  pendingHeightDelta = 0;
  NS_DURING
    [[NSNotificationCenter defaultCenter]
      postNotificationName: NSApplicationDidChangeScreenParametersNotification
		    object: NSApp];
  NS_HANDLER
    postingHeightDelta = 0;
    [localException raise];
  NS_ENDHANDLER
  postingHeightDelta = 0;
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
#ifdef WS_ACTIVATE_RAISE
      /* The app activates itself (it started, or another app asked it
	 to, as Workspace and the Dock do): its windows come forward,
	 those of connections that joined it too (XLibre's X server),
	 which the app can't order itself. */
      ws_activate_flags(conn, WS_ACTIVATE_RAISE);
#else
      ws_activate(conn);
#endif
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
  /* Window tiling: panels (alerts, sheets, inspectors), windows the
     user can't resize, and every window of an app whose NBNeverTile
     default is YES float above the tiled windows. */
  if (nswin != nil && (ws_server_flags(conn) & WS_SERVER_TILING) != 0)
    {
      NSUInteger style = [nswin styleMask];

      if ([nswin isKindOfClass: [NSPanel class]]
	  || (style & (NSUtilityWindowMask | NSDocModalWindowMask)) != 0)
	flags |= WS_WINDOW_PANEL;
      if ((style & NSResizableWindowMask) == 0)
	flags |= WS_WINDOW_FIXED_SIZE;
      if ([[NSUserDefaults standardUserDefaults] boolForKey: @"NBNeverTile"])
	flags |= WS_WINDOW_NO_TILE;
    }
#ifdef WS_SERVER_DRAG
  /* Drag and drop: some view of the window registered dragged types, so
     WindowServer sends it the drags that pass over it. */
  if (nswin != nil && (ws_server_flags(conn) & WS_SERVER_DRAG) != 0
      && [[self dragTypesForWindow: nswin] count] > 0)
    flags |= WS_WINDOW_ACCEPTS_DRAGS;
#endif
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

/* ---- drag and drop (NextBSDDragView) ---- */

- (id <NSDraggingInfo>) dragInfo
{
  return [NextBSDDragView sharedDragView];
}

/* A window that takes drags tells WindowServer (WS_WINDOW_ACCEPTS_DRAGS),
   once it has a WindowServer window. */
- (void) _dragTypesChanged: (NSWindow *)win
{
  nextbsd_window_t *w = [self windowWithNumber: [win windowNumber]];

  if (w != NULL)
    [self updateFlags: w];
}

- (BOOL) addDragTypes: (NSArray *)types toWindow: (NSWindow *)win
{
  BOOL changed = [super addDragTypes: types toWindow: win];

  if (changed)
    [self _dragTypesChanged: win];
  return changed;
}

- (BOOL) removeDragTypes: (NSArray *)types fromWindow: (NSWindow *)win
{
  BOOL changed = [super removeDragTypes: types fromWindow: win];

  if (changed)
    [self _dragTypesChanged: win];
  return changed;
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

- (NSRect) visibleFrameForScreen: (int)aScreen
{
  if (!haveUsableArea || usable.width <= 0 || usable.height <= 0)
    return NSZeroRect;
  return [self nsRectFromWSRect: usable];
}

/*
 * The screen changed size or mode. WindowServer keeps window frames in
 * top-left coordinates, so in GNUstep's bottom-left ones every window
 * moves by the change in height. The NSWindows hear it once the
 * window-frame events of the windows WindowServer moved onto the
 * smaller screen are in too (-_notifyAllFrames), before the
 * notification.
 */
- (void) _screenChanged: (const ws_screen_info_t *)info
{
  CGFloat	    delta;
  NSMapEnumerator   e;
  void		   *key;
  nextbsd_window_t *w;

  if (info->screen_id != screen.screen_id)
    return;
  delta = (CGFloat)info->height - (CGFloat)screen.height;
  [self setScreenInfo: info];
  if (!haveUsableArea)
    {
      usable.x = usable.y = 0;
      usable.width = (int32_t)info->width;
      usable.height = (int32_t)info->height;
    }
  if (delta != 0)
    {
      e = NSEnumerateMapTable(windows);
      while (NSNextMapEnumeratorPair(&e, &key, (void **)&w))
	w->frame.origin.y += delta;
      NSEndMapTableEnumeration(&e);
    }
  pendingHeightDelta += delta;
  screenParamsPending = YES;
  NSDebugLLog(@"NextBSD", @"screen changed: %ux%u", info->width,
	      info->height);
}

/*
 * The Dock moved or changed size (or the screen changed, after
 * -_screenChanged:). NSScreen's visibleFrame follows at once, since the
 * wrapper asks every time. A Dock change alone posts no
 * NSApplicationDidChangeScreenParametersNotification: libs-gui answers
 * it by redisplaying every window, which costs a redraw of the whole
 * desktop on each Dock move and blanks Terminal's windows until their
 * next output.
 */
- (void) _usableAreaChanged: (ws_rect_t)area
{
  if (!haveUsableArea)
    return;
  usable = area;
  NSDebugLLog(@"NextBSD", @"usable area %d,%d %dx%d", area.x, area.y,
	      area.width, area.height);
  [self _keepMenusOutOfDock];
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
  w->serverLevel = NSNormalWindowLevel;
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
  [self _windowClosed: win];
  [self _stackRemove: win];
  if (pointerWindow == win)
    pointerWindow = 0;
  free(w);
  [self _updatePopupGrab];
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
  nextbsd_window_t *w = [self windowWithNumber: win];

  /* A window made resizable or not floats or tiles from now on. */
  if (w != NULL && w->visible)
    [self updateFlags: w];
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
  /* The minimize style decides, as for -appOwnsMiniwindow just before.
     libs-gui keeps a window's miniwindow once it has made one and shows
     it again on every later minimize, so a window first minimized in the
     NeXT style can still get a tile: -orderwindow::: then keeps its
     miniwindow out. Without a miniwindow there's always a tile. */
  w->tiled = serverMinimizes
    && ([GSWindowWithNumber(win) counterpart] == nil
	|| ![minimizeStyle() isEqualToString: @"nextstep"]);
  if (w->tiled)
    {
      /* WindowServer orders the window out and shows a live tile of it,
	 badged with the app icon, until the app orders it in again. */
      [self uploadAppIconIfChanged];
#ifdef WS_SERVER_MINIMIZE_WHERE
      ws_window_minimize_where(conn, w->number, minimizeWhere());
#else
      ws_window_minimize(conn, w->number);
#endif
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

/* A libs-gui miniwindow whose window is minimized to a WindowServer
   tile instead (the style changed since the miniwindow was made). */
- (BOOL) _isMiniwindowOfTiledWindow: (int)win
{
  NSWindow	   *mini = GSWindowWithNumber(win);
  NSWindow	   *main;
  nextbsd_window_t *mw;

  if (mini == nil || ([mini styleMask] & NSMiniWindowMask) == 0)
    return NO;
  main = [mini counterpart];
  if (main == nil)
    return NO;
  mw = [self windowWithNumber: [main windowNumber]];
  return mw != NULL && mw->tiled;
}

- (BOOL) appOwnsMiniwindow
{
  /* With NO, libs-gui makes no miniwindow and leaves minimizing to
     -miniwindow:. The NBMinimizeStyle desktop setting chooses, for each
     window as it's minimized: NeXT miniwindows drawn by libs-gui, or
     WindowServer's previews, on the bottom row ("previews") or in the
     Dock ("dock"; -miniwindow: tells WindowServer which). */
  if (!serverMinimizes)
    return YES;
  return [minimizeStyle() isEqualToString: @"nextstep"];
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
  if (op != NSWindowOut && [self _isMiniwindowOfTiledWindow: win])
    return;
  if (op == NSWindowOut)
    {
      w->visible = NO;
      [self _stackRemove: w->number];
      ws_window_order(conn, w->number, WS_ORDER_OUT, 0);
      [self _updatePopupGrab];
      return;
    }
  [self updateFlags: w];
  /* A menu window shown again after the menu style changed. */
  if (w->serverLevel != [self _serverLevel: w])
    {
      w->serverLevel = [self _serverLevel: w];
      ws_window_set_level(conn, w->number, w->serverLevel);
    }
  [self _keepMenuOnScreen: w];
  [self _stackPlace: w op: op relativeTo: otherWin];
  w->visible = YES;
  w->miniaturized = NO;
  w->tiled = NO;
  ws_window_order(conn, w->number,
		  op == NSWindowBelow ? WS_ORDER_BELOW : WS_ORDER_ABOVE,
		  otherWin > 0 ? (uint32_t)otherWin : 0);
  /* A main menu shown: the Mac menu bar's height, if it changed (an app
     can make its main menu late, after it finished launching). */
  if (w->level == NSMainMenuWindowLevel)
    [self _reportMenuBar];
  [self _focusModalWindow: w];
  [self _updatePopupGrab];
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

/*
 * The NeXT main menu sits at the main-menu level, under the Dock: keep
 * it out of the Dock's strip (the screen outside the usable area),
 * wherever it's put, libs-gui's default place, a saved NSMenuLocations
 * position or a drag, and when the Dock moves. Anywhere else it may go,
 * even partly off the screen.
 */
- (NSRect) _frameOutOfDock: (NSRect)frame
{
  NSRect  u = [self visibleFrameForScreen: screen.screen_id];
  CGFloat sw = screen.width, sh = screen.height;

  if (NSIsEmptyRect(u))
    return frame;
  if (NSMinX(u) > 0 && NSMinX(frame) < NSMinX(u))
    frame.origin.x = NSMinX(u);				/* left Dock */
  else if (NSMaxX(u) < sw && NSMaxX(frame) > NSMaxX(u)
	   && NSWidth(frame) <= NSWidth(u))
    frame.origin.x = NSMaxX(u) - NSWidth(frame);	/* right Dock */
  if (NSMaxY(u) < sh && NSMaxY(frame) > NSMaxY(u)
      && NSHeight(frame) <= NSHeight(u))
    frame.origin.y = NSMaxY(u) - NSHeight(frame);	/* top Dock */
  else if (NSMinY(u) > 0 && NSMinY(frame) < NSMinY(u))
    frame.origin.y = NSMinY(u);				/* bottom Dock */
  return frame;
}

- (NSRect) _menuFrameOnScreen: (NSRect)frame window: (nextbsd_window_t *)w
{
  NSRect  b = NSMakeRect(0, 0, screen.width, screen.height);
  NSRect  sup, u;

  if (w->level == NSMainMenuWindowLevel)
    {
      /* The Mac menu bar stays along the top: the menu bar strip, which
	 the usable area leaves out and a top Dock sits below. */
      if ([self _isMacMenuBar: w])
	return frame;
      return [self _frameOutOfDock: frame];
    }
  if (![self _isMenuLevel: w->level] || NSIsEmptyRect(b))
    return frame;
  /* Submenus and torn-off menus are under the Dock too: keep them in
     the usable area. Pop-up menus are above it, and so are the Mac menu
     bar's menus (-_serverLevel:), which drop down over a top Dock. */
  u = [self visibleFrameForScreen: screen.screen_id];
  if (w->level == NSSubmenuWindowLevel && !NSIsEmptyRect(u)
      && ![self _isMacBarMenu: w])
    b = u;
  if (NSWidth(frame) <= NSWidth(b))
    {
      if (NSMaxX(frame) > NSMaxX(b))
	{
	  sup = [self _supermenuFrame: w->number];
	  if (!NSIsEmptyRect(sup) && NSMinX(frame) >= NSMidX(sup)
	      && NSMinX(sup) - NSWidth(frame) >= NSMinX(b))
	    frame.origin.x = NSMinX(sup) - NSWidth(frame);
	  else
	    frame.origin.x = NSMaxX(b) - NSWidth(frame);
	}
      if (NSMinX(frame) < NSMinX(b))
	frame.origin.x = NSMinX(b);
    }
  if (NSHeight(frame) <= NSHeight(b))
    {
      if (NSMinY(frame) < NSMinY(b))
	frame.origin.y = NSMinY(b);
      if (NSMaxY(frame) > NSMaxY(b))
	frame.origin.y = NSMaxY(b) - NSHeight(frame);
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

- (void) _keepMenusOutOfDock
{
  NSMapEnumerator   e;
  void		   *key;
  nextbsd_window_t *w;

  e = NSEnumerateMapTable(windows);
  while (NSNextMapEnumeratorPair(&e, &key, (void **)&w))
    {
      if (w->visible && (w->level == NSMainMenuWindowLevel
			 || w->level == NSSubmenuWindowLevel))
	[self _keepMenuOnScreen: w];
    }
  NSEndMapTableEnumeration(&e);
}

/*
 * The popup grab (WS_SERVER_POINTER_GRAB). A menu that stays open after
 * the click that opened it (a pop-up button's menu, a context menu, a
 * menu of the Mac menu bar or of a window's menu bar) waits in libs-gui's
 * tracking loop for the next click. A click on another app's window or
 * on the desktop never reaches the app, so the menu would stay open. A
 * WS_GRAB_OUTSIDE grab, held while such a menu is on screen, makes
 * WindowServer report that click (WS_EVENT_POINTER_OUTSIDE), and the
 * backend gives the tracking loop a click there, outside every menu:
 * the menu closes and nothing is chosen.
 *
 * The NeXT style's menus stay out of it: the main menu, its attached
 * submenus and torn-off menus stay on screen by design. Its pop-ups and
 * transient (right-click) menus are at NSPopUpMenuWindowLevel and count.
 */
- (BOOL) _isPopupMenu: (nextbsd_window_t *)w
{
  static Class menuPanelClass = Nil;

  if (!w->visible || !(w->level == NSPopUpMenuWindowLevel
		       || w->level == NSSubmenuWindowLevel))
    return NO;
  if (menuPanelClass == Nil)
    menuPanelClass = NSClassFromString(@"NSMenuPanel");
  /* Tool tips are at NSPopUpMenuWindowLevel too, and
     NSSubmenuWindowLevel is NSFloatingWindowLevel: only menus. */
  if (menuPanelClass == Nil
      || ![GSWindowWithNumber(w->number) isKindOfClass: menuPanelClass])
    return NO;
  return w->level == NSPopUpMenuWindowLevel
    || NSInterfaceStyleForKey(@"NSMenuInterfaceStyle", nil)
       != NSNextStepInterfaceStyle;
}

/* The app's topmost open menu or pop-up, or NULL. */
- (nextbsd_window_t *) _topPopupMenu
{
  NSUInteger i = [stack count];

  while (i-- > 0)
    {
      nextbsd_window_t *w = [self windowWithNumber:
				    [[stack objectAtIndex: i] intValue]];

      if (w != NULL && [self _isPopupMenu: w])
	return w;
    }
  return NULL;
}

- (void) _updatePopupGrab
{
#ifdef WS_SERVER_POINTER_GRAB
  BOOL want;

  if (!pointerGrabs || conn == NULL)
    return;
  want = [self _topPopupMenu] != NULL;
  if (want == popupGrabbed)
    return;
  if (want)
    {
      /* Only the active app may grab (EPERM otherwise); an inactive
	 app's menus close when it's deactivated anyway. */
      if (NSApp == nil || ![NSApp isActive])
	return;
      popupGrabbed = ws_pointer_grab(conn, WS_GRAB_OUTSIDE) == 0;
      NSDebugLLog(@"NextBSD", @"popup grab %s",
		  popupGrabbed ? "taken" : strerror(errno));
      /* ws_pointer_grab waits for its answer, and may have read events
	 into the queue meanwhile. */
      [self scheduleDispatch];
    }
  else
    {
      popupGrabbed = NO;
      ws_pointer_ungrab(conn);
      NSDebugLLog(@"NextBSD", @"popup grab released");
    }
#endif
}

- (void) _popupGrabEnded
{
  if (popupGrabbed)
    NSDebugLLog(@"NextBSD", @"popup grab ended by WindowServer");
  popupGrabbed = NO;
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
  /* libs-gui's second move for the screen change (see
     -_postScreenParameters): the frame is right already. */
  if (postingHeightDelta != 0 && NSEqualSizes(rect.size, w->frame.size)
      && NSMinX(rect) == NSMinX(w->frame)
      && NSMinY(rect) == NSMinY(w->frame) + postingHeightDelta)
    rect = w->frame;
  rect = [self _menuFrameOnScreen: rect window: w];
  if (!NSEqualRects(rect, w->frame))
    {
      [self _windowPlacedByApp: win];
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
      /* libs-gui levels are WindowServer levels (but see
	 -_serverLevel:). */
      w->serverLevel = [self _serverLevel: w];
      ws_window_set_level(conn, w->number, w->serverLevel);
      if (w->visible)
	{
	  [self _stackPlace: w op: NSWindowAbove relativeTo: 0];
	  /* the main menu now: out of the Dock's strip */
	  [self _keepMenuOnScreen: w];
	}
    }
  [self updateFlags: w];
  if (w->visible)
    [self _updatePopupGrab];
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

/* One side of a size limit for WindowServer: 0 for none. */
static uint32_t
sizeLimit(CGFloat v)
{
  /* libs-gui's default maximum is 10000 x 10000 */
  return (v <= 1 || v >= 10000) ? 0 : (uint32_t)v;
}

/* The window's minimum and maximum size: window tiling floats a window
   whose minimum is larger than its tile (WS_SERVER_TILING). */
- (void) _sendSizeLimits: (nextbsd_window_t *)w
{
  if ((ws_server_flags(conn) & WS_SERVER_TILING) == 0)
    return;
  ws_window_set_size_limits(conn, w->number,
    sizeLimit(w->minSize.width), sizeLimit(w->minSize.height),
    sizeLimit(w->maxSize.width), sizeLimit(w->maxSize.height));
}

- (void) setmaxsize: (NSSize)size : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w == NULL || NSEqualSizes(size, w->maxSize))
    return;
  w->maxSize = size;
  [self _sendSizeLimits: w];
}

- (void) setminsize: (NSSize)size : (int)win
{
  nextbsd_window_t *w = [self windowWithNumber: win];

  if (w == NULL || NSEqualSizes(size, w->minSize))
    return;
  w->minSize = size;
  [self _sendSizeLimits: w];
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
      if (w->miniaturized && w->tiled && !w->visible)
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

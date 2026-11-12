/* <title>NextBSDServer</title>

   <abstract>Backend server for the NextBSD WindowServer.</abstract>

   Copyright (C) 2020 Free Software Foundation, Inc.
   Copyright (C) 2026 Joseph Maloney

   Structure adapted from the Wayland backend (WaylandServer.h) by
   Sergio L. Pascual <slp@sinrega.org> and
   Riccardo Canalicchio <riccardo.canalicchio(at)gmail.com>.

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

/*
 * The NextBSD backend talks to WindowServer
 * (/System/Library/CoreServices/WindowServer) through libWindowServerClient.
 * WindowServer composites the windows, stacks them by the libs-gui window
 * levels, owns the input devices and decides which app is active. Apps
 * draw their own windows (title bars included, since libs-gui decorates
 * them) with cairo into shared buffers.
 *
 * Window numbers are WindowServer window ids, which are unique across
 * all apps.  WindowServer coordinates have a top-left origin; the
 * backend converts them to and from the bottom-left origin of GNUstep.
 *
 * Minimized windows: when WindowServer can minimize windows itself
 * (WS_SERVER_MINIMIZE), -appOwnsMiniwindow is NO, so libs-gui draws no
 * miniwindow. WindowServer shows a live, scaled-down tile of the window
 * with the app's icon, which the backend uploads, and asks for the
 * window back with WS_EVENT_WINDOW_RESTORE when the tile is
 * double-clicked; the backend then calls -[NSWindow deminiaturize:].
 * The tile goes on the bottom row, or into the Dock when the user's
 * NBMinimizeStyle is "dock" (WS_SERVER_MINIMIZE_WHERE; the bottom row
 * while no Dock is connected). With an older WindowServer the app
 * draws its miniwindows as before.
 *
 * The usable area (WS_SERVER_USABLE_AREA): WindowServer tells every app
 * the screen minus the strip the Dock keeps on its edge, and the backend
 * reports it as NSScreen's visibleFrame (-visibleFrameForScreen:), so
 * libs-gui centres, cascades, constrains and zooms windows inside it,
 * and places the NeXT main menu at its top-left: below a top Dock,
 * right of a left one. The main menu, and submenus and torn-off menus,
 * are also kept out of the Dock's strip wherever they're put, a saved
 * NSMenuLocations position and a later Dock move included. Screen
 * changes (WS_EVENT_SCREEN_CHANGED) move every window's GNUstep frame
 * with the screen's height, reset NSScreen and post
 * NSApplicationDidChangeScreenParametersNotification once the events
 * that came with them are handled.
 *
 * The menu style (nextbsd/libs-back#3): the NBMenuStyle desktop setting
 * ("nextstep", "inwindow" or "macmenubar"; the user's value, else the
 * theme's, else nextstep) picks libs-gui's NSMenuInterfaceStyle: NeXT
 * floating menus with tear-off, menus in every window
 * (NSWindows95InterfaceStyle), or a Mac menu bar along the top
 * (NSMacintoshInterfaceStyle). The backend keeps it in a volatile
 * defaults domain above the user's, and switches the running app when
 * Workspace Preferences posts org.nextbsd.DesktopSettingsChanged for
 * NBMenuStyle or the theme changes, by rebuilding the main menu's
 * representation the way GSTheme does on a theme change (-[NSMenu
 * setMain:]). In the Mac style the app tells WindowServer its bar's
 * height (WS_SERVER_MENU_BAR), so the usable area and a top Dock stay
 * below the bar, keeps the bar at the top, and the bar's menus drop
 * down over a top Dock.
 */

#ifndef _NextBSDServer_h_INCLUDE
#define _NextBSDServer_h_INCLUDE

#include "config.h"

#include <GNUstepGUI/GSDisplayServer.h>
#include <WindowServer/WSClient.h>

@class NextBSDCairoShmSurface;
@class NSImage;
@class NSTimer;

/* One GNUstep window, as the backend sees it. */
typedef struct nextbsd_window
{
  int		 number;	/* the WindowServer window id */
  NSRect	 frame;		/* GNUstep screen coordinates */
  int		 level;
  int		 serverLevel;	/* the level WindowServer has (-_serverLevel:) */
  uint32_t	 flags;		/* WS_WINDOW_* last sent to the server */
  BOOL		 visible;
  BOOL		 ignoresMouse;
  BOOL		 miniaturized;
  BOOL		 tiled;		/* minimized to a WindowServer tile */
  NSBackingStoreType type;
  NextBSDCairoShmSurface *surface; /* current surface, not retained */
} nextbsd_window_t;

/* Cursor handles given to libs-gui (the cid of the cursor methods). */
typedef struct nextbsd_cursor
{
  uint32_t	 kind;		/* WS_CURSOR_* */
  ws_buffer_t	*image;		/* for WS_CURSOR_CUSTOM */
  int32_t	 hot_x;
  int32_t	 hot_y;
} nextbsd_cursor_t;

@interface NextBSDServer : GSDisplayServer
{
  ws_connection_t	*conn;
  NSMapTable		*windows;	/* window number -> nextbsd_window_t */
  NSMutableArray	*stack;		/* our visible windows, bottom to top */
  ws_screen_info_t	 screen;
  BOOL			 dispatchScheduled;
  BOOL			 serverActivating;
  BOOL			 serverDeactivating;
  /* pointer state */
  NSPoint		 pointerScreen;	/* WindowServer coordinates */
  int			 pointerWindow;
  nextbsd_cursor_t	*currentCursor;
  nextbsd_cursor_t	*arrowCursor;
  BOOL			 cursorHidden;
  float			 scrollMultiplier;
  float			 scrollPixelsPerLine;
  /* the usable area (WS_SERVER_USABLE_AREA), WindowServer coordinates */
  ws_rect_t		 usable;
  BOOL			 haveUsableArea;
  /* NSApplicationDidChangeScreenParametersNotification is due once the
     events read so far are handled; the screen's height changed by
     pendingHeightDelta since the last one (see -_postScreenParameters) */
  BOOL			 screenParamsPending;
  CGFloat		 pendingHeightDelta;
  CGFloat		 postingHeightDelta;
  /* minimizing (WS_SERVER_MINIMIZE) */
  BOOL			 serverMinimizes;
  NSImage		*uploadedIcon;	/* app icon WindowServer has */
  NSTimer		*previewTimer;	/* not retained; the run loop has it */
  /* the menu style (NextBSDServer+MenuStyle.m) */
  int			 reportedMenuBar; /* WS_MSG_SET_MENU_BAR sent, -1 none */
  BOOL			 launched;	/* NSApplicationWillFinishLaunching */
  NSArray		*tornOffMenus;	/* to show again back in NeXT style */
  NSArray		*nextMenuOrder;	/* the main menu's items in NeXT style */
}

/* The connection, for the cairo surfaces. */
+ (ws_connection_t *) connection;
- (ws_connection_t *) connection;

/*
 * This app's WindowServer credentials, for a helper process that should
 * be part of the same app, such as the X server XLibre.app starts.
 * Returns a dictionary with
 *
 *   @"ClientID"	NSNumber (unsigned int), ws_client_id()
 *   @"Token"		NSNumber (unsigned long long), ws_client_token()
 *
 * The helper passes both to ws_connect_join() (libWindowServerClient),
 * and WindowServer then activates it together with this app and lets
 * the two share the key window, so clicking the helper's windows keeps
 * this app active and its menu on screen. Anyone holding the token can
 * join, so give it to the helper through a pipe or its environment,
 * never on a command line other users can read with ps.
 *
 * This header isn't installed, so an app calls it by selector:
 *
 *   id server = GSCurrentServer();
 *   SEL sel = @selector(windowServerAppCredentials);
 *   NSDictionary *creds = [server respondsToSelector: sel]
 *     ? [server performSelector: sel] : nil;
 *
 * nil means the app isn't running on the NextBSD backend.
 */
- (NSDictionary *) windowServerAppCredentials;

- (nextbsd_window_t *) windowWithNumber: (int)win;
- (CGFloat) screenHeight;

/* Convert a GNUstep screen rect to a WindowServer rect and back. */
- (void) setScreenInfo: (const ws_screen_info_t *)info;

/* NSScreen's visibleFrame for the screen: the usable area WindowServer
   reports, in GNUstep coordinates, or NSZeroRect from servers without
   one (libs-gui's own answer then counts). */
- (NSRect) visibleFrameForScreen: (int)aScreen;
/* WS_EVENT_SCREEN_CHANGED and WS_EVENT_USABLE_AREA. */
- (void) _screenChanged: (const ws_screen_info_t *)info;
- (void) _usableAreaChanged: (ws_rect_t)area;
/* Reset NSScreen and post NSApplicationDidChangeScreenParametersNotification. */
- (void) _postScreenParameters;
- (void) _notifyAllFrames;
- (ws_rect_t) wsRectFromNSRect: (NSRect)r;
- (NSRect) nsRectFromWSRect: (ws_rect_t)r;

/* Send GSAppKitWindowMoved/Resized if the NSWindow's frame differs. */
- (void) _notifyFrame: (nextbsd_window_t *)w post: (BOOL)post;

/* Run ws_dispatch() soon from the run loop. Use after calls that may
   read events into the client library's queue. */
- (void) scheduleDispatch;
- (void) dispatchEvents;
@end

@interface NextBSDServer (WindowOps)
/* Keep the local copy of the stacking order (op is NSWindowAbove or
   NSWindowBelow, rel a window number or 0). */
- (void) _stackPlace: (nextbsd_window_t *)w op: (int)op relativeTo: (int)rel;
/* Make the app's modal window key when it comes on screen. */
- (void) _focusModalWindow: (nextbsd_window_t *)w;
- (void) _postFocusIn: (int)win;
/* Keep menu windows (submenu and pop-up levels) on screen. */
- (BOOL) _isMenuLevel: (int)level;
- (NSRect) _supermenuFrame: (int)win;
- (NSRect) _menuFrameOnScreen: (NSRect)frame window: (nextbsd_window_t *)w;
- (void) _keepMenuOnScreen: (nextbsd_window_t *)w;
/* The usable area changed: move menus out of the Dock's strip. */
- (void) _keepMenusOutOfDock;
@end

@interface NextBSDServer (Events)
- (void) handleEvent: (const ws_event_t *)event;
@end

@interface NextBSDServer (Minimize)
/* Give WindowServer the app icon if it changed since the last time. */
- (void) uploadAppIconIfChanged;
/* Keep drawing minimized windows, so their tiles stay live. */
- (void) _startPreviewTimer;
@end

@interface NextBSDServer (Cursor)
- (void) setupCursors;
@end

@interface NextBSDServer (MenuStyle)
/* At startup (-initWithAttributes:) and when the server goes away. */
- (void) _setUpMenuStyle;
- (void) _tearDownMenuStyle;
/* Look NBMenuStyle up again and switch the app's menus if it changed. */
- (void) applyMenuStyle;
/* Tell WindowServer the Mac menu bar's height (0 for no bar). */
- (void) _reportMenuBar;
/* The app's main menu shown as the Mac menu bar, and the menus that drop
   down from it, which open over a top Dock. */
- (BOOL) _isMacMenuBar: (nextbsd_window_t *)w;
- (BOOL) _isMacBarMenu: (nextbsd_window_t *)w;
/* The level WindowServer stacks the window at: libs-gui's, except for
   the Mac menu bar's menus (above the Dock, as pop-up menus). */
- (int) _serverLevel: (nextbsd_window_t *)w;
@end

/* A NextBSD desktop setting (NextBSDServer.m): the user's value, else
   the active theme's, else `builtin`. As nextbsd-theme's
   NBDesktopSettings.h. */
NSString *NextBSDDesktopSetting(NSString *key, NSArray *allowed,
				NSString *builtin);

#endif /* _NextBSDServer_h_INCLUDE */

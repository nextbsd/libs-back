/* NextBSDServer+MenuStyle: the NBMenuStyle desktop setting.

   Copyright (C) 2026 Joseph Maloney

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
 * NextBSD's menu style (nextbsd/libs-back#3, E36 "Menus"): one setting,
 * NBMenuStyle, for every GNUstep app on WindowServer.
 *
 *   nextstep	 NeXT menus: floating, vertical, with tear-off (the default)
 *   inwindow	 each window carries the menu (NSWindows95InterfaceStyle)
 *   macmenubar	 one bar along the top for the active app
 *		 (NSMacintoshInterfaceStyle)
 *
 * The value is the user's (Workspace Preferences, NSGlobalDomain), else
 * the active theme's Info.plist, else nextstep, for the window mode in
 * effect (NBWindowMode: stacking and tiling each have their own, in
 * NBModeSettings and the theme's NBModeDefaults), as nextbsd-theme's
 * NBDesktopSettings.h documents.
 *
 * libs-gui reads its menu style from the NSMenuInterfaceStyle default
 * through NSInterfaceStyleForKey(). The backend puts the style there in
 * a volatile defaults domain of its own, right after the command line's
 * (NSArgumentDomain), so it wins over a NSMenuInterfaceStyle in the
 * user's or a theme's defaults, and a -NSMenuInterfaceStyle argument
 * still wins for testing. libs-gui itself is unchanged.
 *
 * Switching live: libs-gui rebuilds the main menu for a new style in
 * -[NSMenu setMain:] when the style differs from its representation's,
 * which is how GSTheme switches styles when a theme activates. The
 * backend does the same when Workspace Preferences posts
 * org.nextbsd.DesktopSettingsChanged for NBMenuStyle, NBWindowMode or
 * NBModeSettings (or for no key), and when the theme changes: it refreshes NSInterfaceStyleForKey()'s
 * cache, then calls -setMain: YES. libs-gui then
 *
 *   - leaving the in-window style, takes the menu out of every window;
 *   - moves items in or out of the app menu (GSTheme -organizeMenu:),
 *     closes the submenus and adds or removes their title bars;
 *   - entering the in-window style, closes the floating menu and puts a
 *     menu bar in every window that can be main;
 *   - otherwise sizes the menu window and places it: the bar at the top
 *     of the screen, or the NeXT menu where it was saved.
 *
 * NeXT torn-off menus are closed when leaving the NeXT style and shown
 * again when coming back to it. The horizontal styles move items into an
 * app menu and libs-gui moves them back to the end of the menu, so the
 * backend puts the NeXT menu's items back in their order too.
 *
 * In the Mac style the app tells WindowServer how tall its bar is
 * (WS_MSG_SET_MENU_BAR, servers with WS_SERVER_MENU_BAR), 0 in the other
 * styles. WindowServer takes the active app's bar off the usable area
 * (NSScreen's visibleFrame here), so windows, zooming, tiling and a top
 * Dock stay below it. The backend keeps the bar at the top, where the
 * Dock's strip rule would otherwise move a main-menu-level window, and
 * stacks the menus that drop down from it above the Dock, as pop-up
 * menus, so they open over a top Dock instead of under it.
 *
 * In the in-window style an app with no window that can be main (and so
 * carry the menu) shows no menu at all, as on a tiling desktop: no
 * floating or torn-off menu, no bar of its own. Its menu comes back
 * with its next window (Workspace opens a File Viewer when its Dock tile
 * is clicked).
 */

#include "config.h"
#include <AppKit/NSApplication.h>
#include <AppKit/NSGraphics.h>
#include <AppKit/NSInterfaceStyle.h>
#include <AppKit/NSMenu.h>
#include <AppKit/NSMenuView.h>
#include <AppKit/NSWindow.h>
#include <Foundation/NSArray.h>
#include <Foundation/NSDebug.h>
#include <Foundation/NSDictionary.h>
#include <Foundation/NSDistributedNotificationCenter.h>
#include <Foundation/NSException.h>
#include <Foundation/NSNotification.h>
#include <Foundation/NSUserDefaults.h>
#include <GNUstepGUI/GSTheme.h>

#include <math.h>

#include "nextbsd/NextBSDServer.h"

/* The setting, its values, and what Workspace Preferences posts. */
static NSString *const NBMenuStyleKey = @"NBMenuStyle";
static NSString *const NBDesktopSettingsChanged =
  @"org.nextbsd.DesktopSettingsChanged";

/* libs-gui's default, and the volatile domain the backend keeps it in. */
static NSString *const GSMenuStyleKey = @"NSMenuInterfaceStyle";
static NSString *const NBMenuStyleDomain = @"NextBSDMenuStyle";

static NSArray *
menuStyles(void)
{
  static NSArray *styles = nil;

  if (styles == nil)
    styles = [[NSArray alloc] initWithObjects:
			    @"nextstep", @"inwindow", @"macmenubar", nil];
  return styles;
}

/* The libs-gui interface style for a menu style. */
static NSString *
interfaceStyleName(NSString *style)
{
  if ([style isEqualToString: @"inwindow"])
    return @"NSWindows95InterfaceStyle";
  if ([style isEqualToString: @"macmenubar"])
    return @"NSMacintoshInterfaceStyle";
  return @"NSNextStepInterfaceStyle";
}

static NSInterfaceStyle
currentMenuInterfaceStyle(void)
{
  return NSInterfaceStyleForKey(GSMenuStyleKey, nil);
}

/*
 * Show a menu that was torn off before the style changed. Its title bar
 * went away in the other styles. libs-gui places a torn-off menu's
 * close button for the title bar's size when it adds the button, so the
 * menu comes back as not torn off (-_rebuildMainMenu), gets its title
 * bar sized, and only then is torn off again.
 */
static void
showTornOff(NSMenu *menu)
{
  [[menu menuRepresentation] update];
  [menu sizeToFit];
  [menu setTornOff: YES];
  [menu display];
}

/* Every torn-off menu under `menu`. */
static void
collectTornOff(NSMenu *menu, NSMutableArray *found)
{
  NSEnumerator *e = [[menu itemArray] objectEnumerator];
  NSMenuItem   *item;

  while ((item = [e nextObject]) != nil)
    {
      NSMenu *sub = [item submenu];

      if (sub == nil)
	continue;
      if ([sub isTornOff])
	[found addObject: sub];
      collectTornOff(sub, found);
    }
}

@implementation NextBSDServer (MenuStyle)

/*
 * Make libs-gui's NSMenuInterfaceStyle the one for `style`. Returns YES
 * if it changed.
 */
- (BOOL) _setInterfaceStyleForMenuStyle: (NSString *)style
{
  NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
  NSString	 *name = interfaceStyleName(style);
  NSMutableArray *list;
  NSUInteger	  i;
  Class		  cache;

  if ([[[defs volatileDomainForName: NBMenuStyleDomain]
	 objectForKey: GSMenuStyleKey] isEqual: name])
    return NO;
  [defs setVolatileDomain: [NSDictionary dictionaryWithObject: name
						       forKey: GSMenuStyleKey]
		  forName: NBMenuStyleDomain];
  list = [[[defs searchList] mutableCopy] autorelease];
  if (![list containsObject: NBMenuStyleDomain])
    {
      i = [list indexOfObject: NSArgumentDomain];
      [list insertObject: NBMenuStyleDomain
		 atIndex: i == NSNotFound ? 0 : i + 1];
      [defs setSearchList: list];
    }
  /* NSInterfaceStyleForKey() caches each key's style and reads them
     again on NSUserDefaultsDidChangeNotification, which may come later;
     the menu is rebuilt now. */
  cache = NSClassFromString(@"GSInterfaceStyle");
  if ([cache respondsToSelector: @selector(defaultsDidChange:)])
    [cache performSelector: @selector(defaultsDidChange:) withObject: nil];
  NSDebugLLog(@"NextBSD", @"menu style %@ (%@)", style, name);
  return YES;
}

/* The user's NBMenuStyle alone, or nil: for the user's window mode,
   without asking the theme (see -_setUpMenuStyle). */
- (NSString *) _userMenuStyle
{
  NSArray  *modes = [NSArray arrayWithObjects: @"stacking", @"tiling", nil];
  NSString *mode = NextBSDDesktopUserSetting(@"NBWindowMode", nil, modes);

  return NextBSDDesktopUserSetting(NBMenuStyleKey,
				   mode != nil ? mode : @"stacking",
				   menuStyles());
}

- (void) _setUpMenuStyle
{
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  NSString	       *style;

  /*
   * Before the main menu is made (a nib, or the app's code), take the
   * user's choice. The theme isn't asked yet: GSTheme loads it on first
   * use, which shouldn't happen inside the backend's initialisation.
   * The full lookup follows when the app finishes launching, and
   * switches the menu if the theme says otherwise.
   */
  style = [self _userMenuStyle];
  if (style != nil)
    [self _setInterfaceStyleForMenuStyle: style];

  [nc addObserver: self
	 selector: @selector(_menuStyleAppWillFinishLaunching:)
	     name: NSApplicationWillFinishLaunchingNotification
	   object: nil];
  [nc addObserver: self
	 selector: @selector(_menuStyleAppDidFinishLaunching:)
	     name: NSApplicationDidFinishLaunchingNotification
	   object: nil];
  [nc addObserver: self
	 selector: @selector(_menuStyleAppDidBecomeActive:)
	     name: NSApplicationDidBecomeActiveNotification
	   object: nil];
  [nc addObserver: self
	 selector: @selector(_menuStyleThemeDidActivate:)
	     name: GSThemeDidActivateNotification
	   object: nil];
}

- (void) _tearDownMenuStyle
{
  if (launched)
    {
      NS_DURING
	[[NSDistributedNotificationCenter defaultCenter]
	  removeObserver: self];
      NS_HANDLER
      NS_ENDHANDLER
    }
  DESTROY(tornOffMenus);
  DESTROY(nextMenuOrder);
}

- (void) _menuStyleAppWillFinishLaunching: (NSNotification *)n
{
  if (launched)
    return;
  launched = YES;
  /* Workspace Preferences says when NBMenuStyle changes. */
  NS_DURING
    {
      [[NSDistributedNotificationCenter defaultCenter]
	addObserver: self
	   selector: @selector(_desktopSettingsChanged:)
	       name: NBDesktopSettingsChanged
	     object: nil];
    }
  NS_HANDLER
    {
      NSLog(@"NextBSD: can't watch %@, the menu style won't change "
	    @"until the app is started again: %@", NBDesktopSettingsChanged,
	    [localException reason]);
    }
  NS_ENDHANDLER
  [self applyMenuStyle];
}

- (void) _menuStyleAppDidFinishLaunching: (NSNotification *)n
{
  /* The bar has its final size now. */
  [self _reportMenuBar];
}

- (void) _menuStyleAppDidBecomeActive: (NSNotification *)n
{
  NSEnumerator *e;
  NSMenu       *m;

  /* Torn-off menus waiting for the app to come back to the front. */
  if (tornOffMenus == nil
      || currentMenuInterfaceStyle() != NSNextStepInterfaceStyle)
    return;
  e = [tornOffMenus objectEnumerator];
  while ((m = [e nextObject]) != nil)
    showTornOff(m);
  DESTROY(tornOffMenus);
}

- (void) _menuStyleThemeDidActivate: (NSNotification *)n
{
  /* A theme declares its own default; the user's choice still wins. */
  if (launched)
    [self applyMenuStyle];
}

- (void) _desktopSettingsChanged: (NSNotification *)n
{
  id key = [[n userInfo] objectForKey: @"key"];

  /* The menu style, or the window mode, which has its own. */
  if (key != nil && ![key isEqual: NBMenuStyleKey]
      && ![key isEqual: @"NBWindowMode"] && ![key isEqual: @"NBModeSettings"])
    return;
  /* Read what Workspace Preferences just saved. */
  [[NSUserDefaults standardUserDefaults] synchronize];
  [self applyMenuStyle];
}

- (void) applyMenuStyle
{
  NSString *style;

  style = NextBSDDesktopSetting(NBMenuStyleKey, menuStyles(), @"nextstep");
  if ([self _setInterfaceStyleForMenuStyle: style])
    [self _rebuildMainMenu];
  [self _reportMenuBar];
}

/*
 * Leaving the Mac style while this app's bar sets the strip: the strip
 * goes once WindowServer hears our 0, but the NeXT menu is placed now,
 * at the top of the usable area. Take the strip off our copy of it
 * first, so the menu goes to the top (or just below a top Dock).
 */
- (void) _dropOwnMenuBarStrip
{
#ifdef WS_SERVER_MENU_BAR
  if (haveUsableArea && [NSApp isActive] && reportedMenuBar > 0
      && (int)ws_menu_bar_height(conn) == reportedMenuBar
      && usable.y >= reportedMenuBar)
    {
      usable.y -= reportedMenuBar;
      usable.height += reportedMenuBar;
    }
#endif
}

/*
 * The style changed: rebuild the main menu for it, as GSTheme does when
 * a theme activates. -[NSMenu setMain:] compares the style with its
 * representation's, so it does nothing when they're the same.
 */
- (void) _rebuildMainMenu
{
  NSMenu	   *main = [NSApp mainMenu];
  NSInterfaceStyle  old, new;
  NSMutableArray   *found;
  id		    rootLocation;
  NSEnumerator	   *e;
  NSMenu	   *m;

  if (main == nil)
    return;
  old = [[main menuRepresentation] interfaceStyle];
  new = currentMenuInterfaceStyle();
  if (old == new)
    return;
  NSDebugLLog(@"NextBSD", @"rebuilding the main menu: style %d -> %d",
	      (int)old, (int)new);

  /* Leaving the NeXT style: torn-off menus have no place in the others.
     libs-gui closes them with every other submenu; keep them to show
     again back in the NeXT style. */
  if (old == NSNextStepInterfaceStyle || old == GSWindowMakerInterfaceStyle)
    {
      found = [NSMutableArray array];
      collectTornOff(main, found);
      if ([found count] > 0)
	ASSIGN(tornOffMenus, found);
      /* Not torn off while away (see showTornOff()). Their places stay
	 in NSMenuLocations for the next launch. */
      e = [found objectEnumerator];
      while ((m = [e nextObject]) != nil)
	[m setTornOff: NO];
      ASSIGN(nextMenuOrder, [NSArray arrayWithArray: [main itemArray]]);
    }

  if (old == NSMacintoshInterfaceStyle)
    [self _dropOwnMenuBarStrip];

  /* Back to the NeXT style in an app that isn't active: libs-gui puts
     the menu where the user left it (NSMenuLocations), but its window
     is hidden, and the move then drops that place from the defaults
     (-[NSMenu _updateUserDefaults:]). Keep it. */
  rootLocation = nil;
  if ((new == NSNextStepInterfaceStyle || new == GSWindowMakerInterfaceStyle)
      && ![NSApp isActive])
    {
      id locations = [[NSUserDefaults standardUserDefaults]
		       objectForKey: @"NSMenuLocations"];

      if ([locations isKindOfClass: [NSDictionary class]])
	rootLocation = [locations objectForKey: @"\033"];
    }

  [main setMain: YES];

  if ([rootLocation isKindOfClass: [NSString class]])
    [self performSelector: @selector(_keepMainMenuLocation:)
	       withObject: rootLocation
	       afterDelay: 0.5];

  if (new == NSNextStepInterfaceStyle || new == GSWindowMakerInterfaceStyle)
    [self _restoreNextMenuOrder: main];

  if (new == NSNextStepInterfaceStyle && tornOffMenus != nil
      && [NSApp isActive])
    {
      e = [tornOffMenus objectEnumerator];
      while ((m = [e nextObject]) != nil)
	showTornOff(m);
      DESTROY(tornOffMenus);
    }
}

/* Put the NeXT main menu's saved place back if libs-gui dropped it. */
- (void) _keepMainMenuLocation: (NSString *)location
{
  NSUserDefaults      *defs = [NSUserDefaults standardUserDefaults];
  id		       old = [defs objectForKey: @"NSMenuLocations"];
  NSMutableDictionary *locations;

  if ([old isKindOfClass: [NSDictionary class]]
      && [old objectForKey: @"\033"] != nil)
    return;
  locations = [old isKindOfClass: [NSDictionary class]]
    ? [[old mutableCopy] autorelease] : [NSMutableDictionary dictionary];
  [locations setObject: location forKey: @"\033"];
  [defs setObject: locations forKey: @"NSMenuLocations"];
  [defs synchronize];
}

/*
 * Back in the NeXT style, GSTheme -organizeMenu: has taken the items out
 * of the app menu and added them at the end ("About", "Preferences..."
 * after "Help"). If the menu still has just the items it had in the
 * NeXT style, put them back in that order.
 */
- (void) _restoreNextMenuOrder: (NSMenu *)main
{
  NSArray    *items = [main itemArray];
  NSUInteger  i, n = [nextMenuOrder count];
  NSMenuItem *item;
  BOOL	      moved = NO;

  if (n == 0 || [items count] != n)
    {
      DESTROY(nextMenuOrder);
      return;
    }
  for (i = 0; i < n; i++)
    if ([items indexOfObjectIdenticalTo: [nextMenuOrder objectAtIndex: i]]
	== NSNotFound)
      {
	DESTROY(nextMenuOrder);
	return;
      }
  for (i = 0; i < n; i++)
    {
      item = [nextMenuOrder objectAtIndex: i];
      if ([[main itemArray] indexOfObjectIdenticalTo: item] == i)
	continue;
      RETAIN(item);
      [main removeItem: item];
      [main insertItem: item atIndex: i];
      RELEASE(item);
      moved = YES;
    }
  DESTROY(nextMenuOrder);
  if (moved)
    {
      [main sizeToFit];
      if ([NSApp isActive])
	[main display];
    }
}

- (void) _reportMenuBar
{
#ifdef WS_SERVER_MENU_BAR
  NSMenu  *main = [NSApp mainMenu];
  int	   height = 0;

  /* An app without a main menu (the Dock) says nothing, so it leaves
     the strip as the app before it set it. */
  if (conn == NULL || main == nil
      || (ws_server_flags(conn) & WS_SERVER_MENU_BAR) == 0)
    return;
  if (currentMenuInterfaceStyle() == NSMacintoshInterfaceStyle
      && [[main menuRepresentation] isHorizontal])
    {
      height = (int)ceil(NSHeight([[[main menuRepresentation] window]
				    frame]));
      if (height < 1)
	height = (int)ceil([NSMenuView menuBarHeight]);
    }
  if (height == reportedMenuBar)
    return;
  reportedMenuBar = height;
  NSDebugLLog(@"NextBSD", @"menu bar %d pixels", height);
  ws_set_menu_bar(conn, (uint32_t)height);
#endif
}

- (BOOL) _isMacMenuBar: (nextbsd_window_t *)w
{
  NSMenu *main;

  if (currentMenuInterfaceStyle() != NSMacintoshInterfaceStyle)
    return NO;
  main = [NSApp mainMenu];
  return main != nil && [[main menuRepresentation] isHorizontal]
    && [[[main menuRepresentation] window] windowNumber] == w->number;
}

- (BOOL) _isMacBarMenu: (nextbsd_window_t *)w
{
  static Class menuPanelClass = Nil;

  if (w->level != NSSubmenuWindowLevel
      || currentMenuInterfaceStyle() != NSMacintoshInterfaceStyle)
    return NO;
  /* NSSubmenuWindowLevel is also NSFloatingWindowLevel: only menus. */
  if (menuPanelClass == Nil)
    menuPanelClass = NSClassFromString(@"NSMenuPanel");
  return menuPanelClass != Nil
    && [GSWindowWithNumber(w->number) isKindOfClass: menuPanelClass];
}

- (int) _serverLevel: (nextbsd_window_t *)w
{
  return [self _isMacBarMenu: w] ? NSPopUpMenuWindowLevel : w->level;
}

@end

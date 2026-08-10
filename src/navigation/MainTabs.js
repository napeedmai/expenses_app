// The main navigator shown once someone's logged in — Home, My Expenses,
// Pending Approvals (reviewers only), Settings.
//
// This REPLACES the old hamburger drawer (see MainDrawer.js, now
// superseded) with a floating bottom "capsule" tab bar, per
// design_combined.html — structurally borrowed from design_4 (a rounded
// pill floating above the bottom edge, text-only tabs, solid highlight on
// the active tab), recolored in the app's blue/slate palette.
//
// REQUIRES a package that likely isn't installed yet — run this once in
// the project folder before testing:
//   npx expo install @react-navigation/bottom-tabs
// (react-native-safe-area-context, used below for insets, is already a
// dependency of @react-navigation/drawer, so nothing extra is needed for
// that import.)
//
// Each tab that can push a detail screen (Add/Edit Expense, Review
// Expense) gets its own small Stack Navigator nested inside so it has a
// proper header/back button — identical structure to the old drawer,
// just mounted under tabs instead.

import React, { useMemo } from 'react';
import { View, Text, TouchableOpacity, StyleSheet } from 'react-native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { getFocusedRouteNameFromRoute } from '@react-navigation/native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { useSession } from '../SessionContext';
import { useTheme } from '../ThemeContext';
import { radius, shadow } from '../theme';

import HomeScreen from '../screens/HomeScreen';
import ExpenseListScreen from '../screens/ExpenseListScreen';
import AddEditExpenseScreen from '../screens/AddEditExpenseScreen';
import PendingApprovalsScreen from '../screens/PendingApprovalsScreen';
import ReviewExpenseScreen from '../screens/ReviewExpenseScreen';
import SettingsScreen from '../screens/SettingsScreen';

const Tab = createBottomTabNavigator();
const HomeStackNav = createNativeStackNavigator();
const ExpensesStackNav = createNativeStackNavigator();
const ApprovalsStackNav = createNativeStackNavigator();

function HomeStack() {
  return (
    <HomeStackNav.Navigator>
      <HomeStackNav.Screen name="Home" component={HomeScreen} options={{ headerShown: false }} />
      <HomeStackNav.Screen name="AddEditExpense" component={AddEditExpenseScreen} options={{ title: 'Expense' }} />
    </HomeStackNav.Navigator>
  );
}

function ExpensesStack() {
  return (
    <ExpensesStackNav.Navigator>
      <ExpensesStackNav.Screen
        name="MyExpensesList"
        component={ExpenseListScreen}
        options={{ headerShown: false }}
      />
      <ExpensesStackNav.Screen
        name="AddEditExpense"
        component={AddEditExpenseScreen}
        options={{ title: 'Expense' }}
      />
    </ExpensesStackNav.Navigator>
  );
}

function ApprovalsStack() {
  return (
    <ApprovalsStackNav.Navigator>
      <ApprovalsStackNav.Screen
        name="PendingApprovalsList"
        component={PendingApprovalsScreen}
        options={{ headerShown: false }}
      />
      <ApprovalsStackNav.Screen
        name="ReviewExpense"
        component={ReviewExpenseScreen}
        options={{ title: 'Review Expense' }}
      />
    </ApprovalsStackNav.Navigator>
  );
}

const TAB_META = {
  HomeTab: { label: 'Home', icon: 'home-outline', iconActive: 'home' },
  ExpensesTab: { label: 'Claims', icon: 'receipt-outline', iconActive: 'receipt' },
  ApprovalsTab: { label: 'Approvals', icon: 'checkmark-done-outline', iconActive: 'checkmark-done' },
  SettingsTab: { label: 'Settings', icon: 'settings-outline', iconActive: 'settings' },
};

// Custom floating pill tab bar — replaces the default bottom-tabs look
// entirely so it matches the capsule nav from design_combined.html.
//
// Hidden on the Add/Edit Expense and Review Expense detail screens — those
// already have their own bottom action bar (Save/Submit, Accept/Revise/
// Reject), so showing both at once would be cluttered and could overlap.
function FloatingTabBar({ state, navigation }) {
  const insets = useSafeAreaInsets();
  const { colors } = useTheme();
  const styles = useMemo(() => createStyles(colors), [colors]);

  const activeTabRoute = state.routes[state.index];
  const focusedChildName = getFocusedRouteNameFromRoute(activeTabRoute);
  if (focusedChildName === 'AddEditExpense' || focusedChildName === 'ReviewExpense') {
    return null;
  }

  return (
    <View style={[styles.wrap, { bottom: Math.max(insets.bottom, 12) + 8 }]} pointerEvents="box-none">
      <View style={[styles.pill, shadow.raised]}>
        {state.routes.map((route, index) => {
          const meta = TAB_META[route.name];
          if (!meta) return null;
          const focused = state.index === index;

          function onPress() {
            const event = navigation.emit({ type: 'tabPress', target: route.key, canPreventDefault: true });
            if (!focused && !event.defaultPrevented) {
              navigation.navigate(route.name);
            }
          }

          return (
            <TouchableOpacity
              key={route.key}
              onPress={onPress}
              style={[styles.tab, focused && styles.tabActive]}
              activeOpacity={0.85}
            >
              <Ionicons name={focused ? meta.iconActive : meta.icon} size={16} color={focused ? '#fff' : '#94a3b8'} />
              <Text style={[styles.tabLabel, focused && styles.tabLabelActive]}>{meta.label}</Text>
            </TouchableOpacity>
          );
        })}
      </View>
    </View>
  );
}

export default function MainTabs() {
  const { session } = useSession();
  const isReviewer = !!(session?.isReportingManager || session?.isFinanceManager);

  return (
    <Tab.Navigator
      initialRouteName="HomeTab"
      screenOptions={{ headerShown: false }}
      tabBar={(props) => <FloatingTabBar {...props} />}
    >
      <Tab.Screen name="HomeTab" component={HomeStack} />
      <Tab.Screen name="ExpensesTab" component={ExpensesStack} />
      {isReviewer ? <Tab.Screen name="ApprovalsTab" component={ApprovalsStack} /> : null}
      <Tab.Screen name="SettingsTab" component={SettingsScreen} />
    </Tab.Navigator>
  );
}

function createStyles(colors) {
  return StyleSheet.create({
  wrap: {
    position: 'absolute',
    left: 16,
    right: 16,
    alignItems: 'center',
  },
  pill: {
    flexDirection: 'row',
    backgroundColor: colors.slate900,
    borderRadius: radius.pill,
    padding: 6,
    width: '100%',
  },
  tab: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 5,
    paddingVertical: 11,
    borderRadius: radius.pill,
  },
  tabActive: { backgroundColor: colors.primary },
  tabLabel: { color: '#94a3b8', fontSize: 11, fontWeight: '700' },
  tabLabelActive: { color: '#fff' },
  });
}
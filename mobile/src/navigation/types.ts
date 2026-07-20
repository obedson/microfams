export type RootStackParamList = {
  Login: undefined;
  Register: undefined;
  ForgotPassword: undefined;
  ResetPassword: { token?: string } | undefined;
  MainTabs: undefined;
  PropertyDetail: { id: string };
  CreateBooking: { propertyId: string };
  MyBookings: undefined;
  BookingDetail: { id: string };
  Courses: undefined;
  CourseDetail: { id: string };
  ProductDetail: { id: string };
  AddProduct: { product?: Record<string, unknown> } | undefined;
  Cart: undefined;
  Checkout: undefined;
  FarmRecords: undefined;
  GroupDetail: { id: string };
  ContributionDashboard: { groupId: string };
  MakeContribution: { contributionId: string; amount: number };
};

export type MainTabParamList = {
  Home: undefined;
  Properties: undefined;
  Groups: undefined;
  Marketplace: undefined;
  Dashboard: undefined;
};

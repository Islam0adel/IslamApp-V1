

class ApiConstants {
  // لما تحب تشتغل محلي (Local) فك التعليق عن السطر اللي تحت واقفل بتاع Hugging Face
  // static const String baseUrl = "http://127.0.0.1:8000";

  // رابط Hugging Face (الرابط ده هو اللي هيكون شغال لما ترفع على Vercel)
  static const String baseUrl = "https://islamadel-islam-app-api.hf.space";

    /// ⭐ VAPID Key من Firebase Console → Project Settings
  /// → Cloud Messaging → Web Push certificates
  /// (public key — آمن للعرض في الكود)
  static const String fcmVapidKey = 'BLqLyqfb7CyW29n62s-Lxa6L2pTyrPv-6WN2ZYDu5Mdi1j1xmIyInk2ubBj-3xENkACLo7794dG6WUNlMQn8OaQ';

  static const String LAST_SYNC_DAILY = 'last_sync_daily_';
  static const String LAST_SYNC_SUPPLIER = 'last_sync_supplier_';
  static const String LAST_SYNC_INVENTORY = 'last_sync_inventory_';
  static const String LAST_SYNC_SETTLEMENT = 'last_sync_settlement_';
  static const String LAST_SYNC_CODING = 'last_sync_coding_';
  static const String LAST_SYNC_COMPANIES = 'last_sync_companies_';
  static const String LAST_SYNC_USERS = 'last_sync_users_';
    // ⭐ Commercial Module
  static const String LAST_SYNC_SALES = 'last_sync_sales_';
  static const String LAST_SYNC_RETURNS = 'last_sync_returns_';
  static const String LAST_SYNC_CUSTOMER_PAYMENTS = 'last_sync_customer_payments_';
  static const String LAST_SYNC_TRANSFERS = 'last_sync_transfers_';
}
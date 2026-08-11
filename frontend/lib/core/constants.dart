

class ApiConstants {
  // لما تحب تشتغل محلي (Local) فك التعليق عن السطر اللي تحت واقفل بتاع Hugging Face
  // static const String baseUrl = "http://127.0.0.1:8000";

  // رابط Hugging Face (الرابط ده هو اللي هيكون شغال لما ترفع على Vercel)
  static const String baseUrl = "https://islamadel-islam-app-api.hf.space";

  static const String LAST_SYNC_DAILY = 'last_sync_daily_';
  static const String LAST_SYNC_SUPPLIER = 'last_sync_supplier_';
  static const String LAST_SYNC_INVENTORY = 'last_sync_inventory_';
  // static const String LAST_SYNC_SETTLEMENT = 'last_sync_settlement_';
  static const String LAST_SYNC_CODING = 'last_sync_coding_';
}
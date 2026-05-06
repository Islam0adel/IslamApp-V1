// class ApiConstants {
//   // استبدل هذا الرابط برابط السيرفر الخاص بك على Hugging Face لاحقاً
//   // لو بتجرب على المحاكي (Emulator) استخدم 10.0.2.2 بدلاً من localhost
//   static const String baseUrl = 'https://your-huggingface-space-url.hf.space';
//   static const String loginEndpoint = '$baseUrl/auth/login';
//   static const String registerEndpoint = '$baseUrl/auth/register';
// }


// class ApiConstants {
//   // جرب localhost لو 127.0.0.1 لسه مدي إيرور في المتصفح
//   static const String baseUrl = 'http://localhost:8000'; 
//   static const String loginEndpoint = '$baseUrl/auth/login';
//   static const String registerEndpoint = '$baseUrl/auth/register';
// }

class ApiConstants {
  // لما تحب تشتغل محلي (Local) فك التعليق عن السطر اللي تحت واقفل بتاع Hugging Face
  // static const String baseUrl = "http://127.0.0.1:8000";

  // رابط Hugging Face (الرابط ده هو اللي هيكون شغال لما ترفع على Vercel)
  static const String baseUrl = "https://islamadel-islam-app-api.hf.space";
}
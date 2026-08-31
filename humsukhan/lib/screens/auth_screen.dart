import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/providers.dart';
import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/reusable_widgets.dart';
import '../l10n/app_strings.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  bool _isSignUp = false;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final s = AppStrings.of(context);

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppTokens.warmIvory, AppTokens.softCream],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 40),
                Center(
                  child: Container(
                    width: 80,
                    height: 80,
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.all(Radius.circular(20)),
                    ),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(20)),
                      child: Image.asset('assets/logo.png', fit: BoxFit.cover),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  _isSignUp ? s.createAccount : s.welcomeBack,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: AppTokens.textDeepForest,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  _isSignUp ? s.signUpDesc : s.signInDesc,
                  style: const TextStyle(
                    fontSize: 14,
                    color: AppTokens.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                if (_isSignUp) ...[
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: s.nameLabel,
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: s.emailLabel,
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  maxLength: _isSignUp ? 8 : null,
                  decoration: InputDecoration(
                    labelText: s.passwordLabel,
                    helperText: _isSignUp ? s.passwordHelper : null,
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: Semantics(
                      label: _obscurePassword ? s.showPassword : s.hidePassword,
                      button: true,
                      child: IconButton(
                        tooltip: _obscurePassword ? s.showPassword : s.hidePassword,
                        icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
                        onPressed: () {
                          setState(() => _obscurePassword = !_obscurePassword);
                        },
                      ),
                    ),
                  ),
                ),
                if (auth.error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTokens.error.withValues(alpha: .1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      auth.error!,
                      style: const TextStyle(
                        color: AppTokens.error,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                PrimaryActionButton(
                  label: auth.isLoading
                      ? s.pleaseWait
                      : (_isSignUp ? s.createAccount : s.signIn),
                  icon: _isSignUp ? Icons.person_add : Icons.login,
                  onPressed: auth.isLoading ? () {} : _handleSubmit,
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: auth.isLoading
                      ? null
                      : () => setState(() => _isSignUp = !_isSignUp),
                  child: Text(
                    _isSignUp ? s.alreadyHaveAccount : s.noAccountSignUp,
                    style: const TextStyle(color: AppTokens.deepSage),
                  ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: auth.isLoading
                      ? null
                      : () async {
                          final success = await auth.signInAnonymously();
                          if (success && context.mounted) {
                            Navigator.of(context).pushReplacementNamed('/home');
                          }
                        },
                  icon: const Icon(Icons.explore, color: AppTokens.deepSage),
                  label: Text(
                    s.tryWithoutAccount,
                    style: TextStyle(color: AppTokens.deepSage),
                  ),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 52),
                    side: const BorderSide(color: AppTokens.deepSage),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pushReplacementNamed('/home'),
                  child: Text(
                    s.skipForNow,
                    style: TextStyle(color: AppTokens.textMuted),
                  ),
                ),
                const SizedBox(height: 24),
                PrivacyNotice(
                  text: s.authPrivacyNotice,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleSubmit() async {
    final s = AppStrings.of(context);
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final name = _nameController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.enterEmailPassword)),
      );
      return;
    }

    if (_isSignUp) {
      final error = AuthService.validatePassword(password);
      if (error != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error)),
        );
        return;
      }
    }

    final auth = context.read<AuthProvider>();
    final success = _isSignUp
        ? await auth.signUp(email: email, password: password, name: name)
        : await auth.signIn(email: email, password: password);

    if (success && mounted) {
      Navigator.of(context).pushReplacementNamed('/home');
    }
  }
}

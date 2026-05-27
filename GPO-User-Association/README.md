# Invoke-GPOUserAssociation.ps1

Script PowerShell avec interface graphique WPF permettant de :

1. **Récupérer les utilisateurs AD** via LDAP
2. **Lister toutes les GPO** du domaine
3. **Associer des GPO à des utilisateurs** (liaison sur leur OU parente)
4. **Déclencher une réplication AD** sur tous les contrôleurs de domaine
5. **Lancer un import incrémentiel OKTA** via l'API REST

---

## Prérequis

- Windows Server avec **RSAT** installé (modules `ActiveDirectory` + `GroupPolicy`)
- Compte avec droits **Domain Admin** (ou délégation GPO + réplication)
- Token API OKTA avec scope `okta.users.manage` et `okta.agents.manage`

## Configuration

Éditer la section `$Config` en haut du script :

```powershell
$Config = @{
    LDAPSearchBase = (Get-ADDomain).DistinguishedName   # Base LDAP (auto-détectée)
    OktaBaseUrl    = "https://YOUR_ORG.okta.com"        # URL de votre tenant OKTA
    OktaApiToken   = "YOUR_OKTA_API_TOKEN"              # Token SSWS ou Bearer
    OktaAgentId    = "YOUR_OKTA_AGENT_ID"               # ID de l'agent AD OKTA
}
```

> ⚠️ **Ne jamais committer le token OKTA** en clair. Utiliser un gestionnaire de secrets (ex: `Get-Secret` du module `Microsoft.PowerShell.SecretManagement`).

## Utilisation

```powershell
# Lancer l'interface
.\Invoke-GPOUserAssociation.ps1
```

Workflow dans l'UI :

| Étape | Action |
|-------|--------|
| 1 | Filtrer et sélectionner les utilisateurs (multi-sélection `Ctrl+clic`) |
| 2 | Filtrer et sélectionner les GPO à associer |
| 3 | Cliquer **✅ Appliquer les GPO** |
| 4 | Cliquer **🔄 Répliquer AD** |
| 5 | Cliquer **☁ Sync OKTA** |

## Architecture du script

```
Show-MainUI
├── Get-ADUserList        → LDAP query (Enabled users)
├── Get-AllGPOs           → Get-GPO -All
├── Apply-GPOToUsers      → New-GPLink sur l'OU parente
├── Invoke-ADReplication  → repadmin /syncall sur chaque DC
└── Invoke-OktaIncrementalImport → POST /api/v1/agents/active_directory/.../import
```

## Notes

- La liaison GPO se fait sur l'**OU parente directe** de l'utilisateur. Adapter `Get-OUFromDN` si vos utilisateurs sont dans des sous-OUs profondes.
- L'endpoint OKTA utilisé peut varier selon la version de votre connecteur AD. Vérifier dans la doc [OKTA API - Import Users](https://developer.okta.com/docs/reference/api/system-log/).

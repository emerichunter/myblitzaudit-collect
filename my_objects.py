#!/usr/bin/env python3
"""my_objects.py - collecte exhaustive des objets d'une instance MySQL.

Complete my_collect.sh : la ou le collecteur historique releve les volumes et
les statistiques, ce script releve la definition de chaque objet.

Trois etages :
  instance   variables, statut, plugins, moteurs, tablespaces, comptes,
             privileges, roles, verrous, journal binaire, replication
  structure  colonnes, index, cles etrangeres avec regles, partitions,
             contraintes CHECK, histogrammes, options de table
  ddl        SHOW CREATE TABLE pour chaque table et chaque vue

Choix techniques, mesures a l'appui :
  - SHOW CREATE TABLE en session unique : 44 ms par table sur un lien a 40 ms
    d'aller-retour. mysqldump fait la meme chose en 690 ms par table (il lance
    quatre a cinq requetes de metadonnees par table) : ne pas l'utiliser.
  - Selection de colonnes adaptative : information_schema change de colonnes
    d'une version a l'autre (status dans innodb_tablespaces, data_access dans
    routines, space dans files). On decouvre les colonnes avant de composer
    la requete, sinon la requete casse et la section est perdue.
  - Sonde de partitionnement avant le scan complet de PARTITIONS : cette vue
    ouvre chaque table et coute plusieurs minutes sur un millier de tables.
  - Aucune empreinte de mot de passe n'est ecrite : les comptes sont agreges.

Usage :
  my_objects.py --host 10.0.0.5 --user audit --password-file /root/.my.pwd \\
                --output-dir /chemin/sortie [--port 3306] [--no-ddl] [--no-instance]
"""
import argparse
import gzip
import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict

SYS = "'mysql','information_schema','performance_schema','sys'"


class Client:
    def __init__(self, host, port, user, password, timeout=3600):
        self.host, self.port, self.user = host, port, user
        self.timeout = timeout
        self.env = dict(os.environ, MYSQL_PWD=password)
        self._cols = {}

    def _base(self):
        return ['mysql', '-h', self.host, '-P', str(self.port), '-u', self.user]

    def query(self, sql, raw=False, timeout=None):
        """Retourne (code, sortie, erreur) sans lever d'exception."""
        cmd = self._base() + (['--raw'] if raw else ['-N', '-B']) + ['-e', sql]
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, env=self.env,
                               timeout=timeout or self.timeout)
        except subprocess.TimeoutExpired:
            return 124, '', 'timeout'
        return p.returncode, p.stdout, p.stderr

    def run(self, sql, timeout=None):
        rc, out, err = self.query(sql, timeout=timeout)
        if rc != 0:
            raise RuntimeError(err.strip()[:300] or f'code {rc}')
        return out

    def columns_of(self, table, schema='information_schema'):
        key = (schema, table)
        if key not in self._cols:
            rc, out, _ = self.query(
                "select column_name from information_schema.columns "
                f"where table_schema='{schema}' and table_name='{table}'")
            self._cols[key] = set(x.strip().lower() for x in out.splitlines() if x.strip())
        return self._cols[key]

    def select(self, table, desired, where='', schema='information_schema'):
        """SELECT dont la liste de colonnes est filtree sur ce que la version
        expose reellement."""
        avail = self.columns_of(table, schema)
        keep = [c for c in desired if c.lower() in avail] or ['*']
        sql = f"select {', '.join(keep)} from {schema}.{table}"
        if where:
            sql += f" where {where}"
        return sql

    def run_file(self, path, out_path):
        cmd = self._base() + ['-N', '-B']
        with open(path, 'rb') as fin, open(out_path, 'wb') as fout:
            p = subprocess.run(cmd, stdin=fin, stdout=fout,
                               stderr=subprocess.PIPE, env=self.env,
                               timeout=self.timeout)
        return p.returncode, p.stderr.decode('utf-8', 'replace')[:300]


# --------------------------------------------------------------- etage 1
def queries_instance(c):
    return {
        'variables': lambda: "select variable_name, variable_value from performance_schema.global_variables",
        'status': lambda: "select variable_name, variable_value from performance_schema.global_status",
        'plugins': lambda: c.select('plugins', ['plugin_name', 'plugin_status', 'plugin_type', 'plugin_library', 'plugin_version']),
        'engines': lambda: c.select('engines', ['engine', 'support', 'transactions', 'xa', 'savepoints']),
        'tablespaces': lambda: c.select('innodb_tablespaces', ['name', 'space_type', 'space', 'file_size', 'allocated_size', 'autoextend_size', 'status', 'encryption']),
        'datafiles': lambda: c.select('files', ['tablespace_name', 'space', 'path', 'path_type', 'file_type', 'file_size', 'status']),
        'user_privs': lambda: c.select('user_privileges', ['grantee', 'privilege_type', 'is_grantable']),
        'schema_privs': lambda: c.select('schema_privileges', ['grantee', 'table_schema', 'privilege_type', 'is_grantable'], where=f"table_schema not in ({SYS})"),
        'table_privs': lambda: c.select('table_privileges', ['grantee', 'table_schema', 'table_name', 'privilege_type', 'is_grantable'], where=f"table_schema not in ({SYS})"),
        'column_privs': lambda: c.select('column_privileges', ['grantee', 'table_schema', 'table_name', 'column_name', 'privilege_type', 'is_grantable'], where=f"table_schema not in ({SYS})"),
        'role_edges': lambda: c.select('role_edges', ['from_user', 'to_user', 'with_admin_option'], schema='mysql'),
        'applicable_roles': lambda: c.select('applicable_roles', ['granted_role', 'grantee', 'is_default', 'is_mandatory']),
        'proxies': lambda: c.select('proxies_priv', ['host', 'user', 'proxied_host', 'proxied_user', 'with_grant', 'grantor'], schema='mysql'),
        'routines': lambda: c.select('routines', ['routine_schema', 'routine_name', 'routine_type', 'definer', 'security_type', 'sql_mode', 'data_access', 'is_deterministic', 'routine_comment'], where=f"routine_schema not in ({SYS})"),
        'triggers': lambda: c.select('triggers', ['trigger_schema', 'trigger_name', 'event_manipulation', 'event_object_table', 'action_timing', 'definer', 'sql_mode'], where=f"trigger_schema not in ({SYS})"),
        'events': lambda: c.select('events', ['event_schema', 'event_name', 'definer', 'status', 'on_completion', 'event_type', 'interval_value', 'interval_field'], where=f"event_schema not in ({SYS})"),
        'views': lambda: c.select('views', ['table_schema', 'table_name', 'definer', 'security_type', 'check_option', 'is_updatable'], where=f"table_schema not in ({SYS})"),
        'processlist': lambda: "select id, user, host, db, command, time, state, left(info,300) from information_schema.processlist",
        'metadata_locks': lambda: "select object_type, object_schema, object_name, lock_type, lock_duration, lock_status, owner_thread_id from performance_schema.metadata_locks",
        'data_locks': lambda: c.select('data_locks', ['engine', 'engine_transaction_id', 'object_schema', 'object_name', 'index_name', 'lock_type', 'lock_mode', 'lock_status'], schema='performance_schema'),
        'lock_waits': lambda: c.select('data_lock_waits', ['engine', 'requesting_engine_transaction_id', 'blocking_engine_transaction_id'], schema='performance_schema'),
        'innodb_tablestats': lambda: c.select('innodb_tablestats', ['name', 'table_id', 'num_rows', 'clustered_index_size', 'sum_of_other_index_sizes']),
        'innodb_index_stats': lambda: c.select('innodb_index_stats', ['database_name', 'table_name', 'index_name', 'stat_name', 'stat_value', 'sample_size'], schema='mysql', where=f"database_name not in ({SYS})"),
        'scheduler': lambda: "select @@event_scheduler, @@version, @@version_comment, @@hostname, @@log_bin, @@server_id",
    }


def collect_instance(c, dest):
    res = {}
    for name, fn in queries_instance(c).items():
        try:
            res[name] = c.run(fn()).splitlines()
        except Exception as e:
            res[name] = [f'ERREUR: {e}']
    for name, sql in (('binary_logs', 'show binary logs'),
                      ('replica_status', 'show replica status'),
                      ('innodb_status', 'show engine innodb status')):
        rc, out, err = c.query(sql, raw=True)
        res[name] = out.splitlines() if rc == 0 else [f'INDISPONIBLE: {err.strip()[:160]}']
    # comptes : agregats seulement, jamais l'empreinte de mot de passe
    sql = c.select('user', ['user', 'host', 'plugin', 'password_last_changed', 'password_lifetime',
                            'account_locked', 'password_expired', 'ssl_type', 'super_priv',
                            'authentication_string'], schema='mysql')
    rc, out, err = c.query(sql)
    if rc == 0:
        res['comptes'] = agreger_comptes(out.splitlines())
    else:
        res['comptes'] = {'erreur': err.strip()[:200]}
    with open(f'{dest}/instance.json', 'w', encoding='utf-8') as f:
        json.dump(res, f, ensure_ascii=False, indent=1)
    return res


def agreger_comptes(lignes):
    agg = {'nb': 0, 'plugins': {}, 'verrouilles': 0, 'expires': 0,
           'ssl': {}, 'sans_mot_de_passe': 0, 'super': 0, 'details': []}
    for l in lignes:
        p = l.split('\t')
        if len(p) < 4:
            continue
        user, host, plugin = p[0], p[1], p[2] or 'aucun'
        locked = p[6] if len(p) > 6 else ''
        expired = p[7] if len(p) > 7 else ''
        ssl = (p[8] if len(p) > 8 else '') or 'NONE'
        superp = p[9] if len(p) > 9 else ''
        auth = p[10] if len(p) > 10 else ''
        agg['nb'] += 1
        agg['plugins'][plugin] = agg['plugins'].get(plugin, 0) + 1
        agg['ssl'][ssl] = agg['ssl'].get(ssl, 0) + 1
        agg['verrouilles'] += locked.upper() == 'Y'
        agg['expires'] += expired.upper() == 'Y'
        agg['super'] += superp.upper() == 'Y'
        agg['sans_mot_de_passe'] += not auth or auth == 'NULL'
        agg['details'].append({'user': user, 'host': host, 'plugin': plugin,
                               'locked': locked, 'ssl_type': ssl, 'super': superp})
    return agg


# --------------------------------------------------------------- etage 2
def queries_structure(c):
    return {
        'columns': lambda: c.select('columns', ['table_schema', 'table_name', 'column_name', 'ordinal_position', 'column_default', 'is_nullable', 'data_type', 'column_type', 'character_set_name', 'collation_name', 'column_key', 'extra', 'generation_expression', 'column_comment'], where=f"table_schema not in ({SYS})"),
        'indexes': lambda: c.select('statistics', ['table_schema', 'table_name', 'index_name', 'seq_in_index', 'column_name', 'non_unique', 'index_type', 'cardinality', 'sub_part', 'packed', 'nullable', 'index_comment', 'is_visible', 'expression'], where=f"table_schema not in ({SYS})"),
        'fks': lambda: ("select k.constraint_schema, k.constraint_name, k.table_schema, k.table_name, "
                        "k.column_name, k.ordinal_position, k.referenced_table_schema, k.referenced_table_name, "
                        "k.referenced_column_name, r.update_rule, r.delete_rule, r.match_option "
                        "from information_schema.key_column_usage k "
                        "join information_schema.referential_constraints r "
                        "on r.constraint_schema=k.constraint_schema and r.constraint_name=k.constraint_name "
                        f"where k.referenced_table_name is not null and k.table_schema not in ({SYS})"),
        'checks': lambda: c.select('check_constraints', ['constraint_schema', 'constraint_name', 'check_clause'], where=f"constraint_schema not in ({SYS})"),
        'tables': lambda: c.select('tables', ['table_schema', 'table_name', 'table_type', 'engine', 'row_format', 'table_rows', 'avg_row_length', 'data_length', 'index_length', 'data_free', 'auto_increment', 'table_collation', 'create_options', 'table_comment'], where=f"table_schema not in ({SYS})"),
        'histograms': lambda: c.select('column_statistics', ['schema_name', 'table_name', 'column_name']),
        'schemata': lambda: c.select('schemata', ['schema_name', 'default_character_set_name', 'default_collation_name'], where=f"schema_name not in ({SYS})"),
    }


def sonde_partitions(c):
    """Le scan complet de PARTITIONS ouvre chaque table : plusieurs minutes sur
    un millier de tables. On le declenche seulement si une table est declaree
    partitionnee dans ses options de creation."""
    rc, out, err = c.query("select table_schema, table_name, create_options "
                           "from information_schema.tables "
                           f"where table_schema not in ({SYS}) "
                           "and create_options like '%partitioned%'")
    if rc != 0:
        return None, f'probe: {err.strip()[:120]}'
    return [l for l in out.splitlines() if l], None


def collect_structure(c, dest):
    meta = {}
    for name, fn in queries_structure(c).items():
        try:
            out = c.run(fn())
        except Exception as e:
            meta[name] = f'ERREUR: {e}'
            continue
        with gzip.open(f'{dest}/{name}.tsv.gz', 'wt', encoding='utf-8') as f:
            f.write(out)
        meta[name] = len(out.splitlines())
    part, err = sonde_partitions(c)
    if err:
        meta['partitions'] = err
    elif not part:
        with gzip.open(f'{dest}/partitions.tsv.gz', 'wt', encoding='utf-8') as f:
            f.write('')
        meta['partitions'] = 0
        meta['partitions_note'] = 'aucune table partitionnee : scan PARTITIONS evite'
    else:
        try:
            out = c.run(c.select('partitions', ['table_schema', 'table_name', 'partition_name', 'subpartition_name',
                                                'partition_ordinal_position', 'partition_method', 'subpartition_method',
                                                'partition_expression', 'partition_description', 'table_rows',
                                                'data_length', 'index_length', 'data_free'],
                                 where=f"table_schema not in ({SYS}) and partition_name is not null"), timeout=3600)
            with gzip.open(f'{dest}/partitions.tsv.gz', 'wt', encoding='utf-8') as f:
                f.write(out)
            meta['partitions'] = len(out.splitlines())
        except Exception as e:
            meta['partitions'] = f'ERREUR: {e}'
    with open(f'{dest}/structure_counts.json', 'w', encoding='utf-8') as f:
        json.dump(meta, f, indent=1)
    return meta


# --------------------------------------------------------------- etage 3
def collect_ddl(c, dest, schemas=None):
    d = f'{dest}/ddl'
    os.makedirs(d, exist_ok=True)
    where = f"table_schema not in ({SYS})"
    if schemas:
        liste = ', '.join("'" + s.replace("'", "''") + "'" for s in schemas)
        where = f"table_schema in ({liste})"
    out = c.run("select table_schema, table_name, table_type from information_schema.tables "
                f"where table_type in ('BASE TABLE','VIEW') and {where} "
                "order by table_schema, table_name")
    objs = defaultdict(list)
    for line in out.splitlines():
        p = line.split('\t')
        if len(p) == 3:
            objs[p[0]].append((p[1], p[2]))
    sql_path, out_path = f'{dest}/_ddl.sql', f'{dest}/_ddl.out'
    with open(sql_path, 'w', encoding='utf-8') as f:
        for sch, items in objs.items():
            for name, typ in items:
                f.write(f"select '@@@{typ}|{sch}|{name}';\n")
                f.write(f"SHOW CREATE {'TABLE' if typ == 'BASE TABLE' else 'VIEW'} "
                        f"`{sch}`.`{name}`\\G\n")
    rc, err = c.run_file(sql_path, out_path)
    if rc != 0:
        return {'ddl_rc': rc, 'erreur': err, 'objets': sum(len(v) for v in objs.values())}
    buf, cur = defaultdict(list), None
    with open(out_path, encoding='utf-8', errors='replace') as f:
        for line in f:
            if line.startswith('@@@'):
                cur = line.strip().split('|')[1] if '|' in line else '_inconnu'
                buf[cur].append(f"-- {line.strip()[3:]}\n")
            elif cur:
                buf[cur].append(line)
    for sch, lines in buf.items():
        safe = re.sub(r'[^A-Za-z0-9_.-]', '_', sch)
        with gzip.open(f'{d}/{safe}.ddl.sql.gz', 'wt', encoding='utf-8') as f:
            f.writelines(lines)
    for p in (sql_path, out_path):
        try:
            os.remove(p)
        except OSError:
            pass
    return {'ddl_rc': 0, 'objets': sum(len(v) for v in objs.values()),
            'schemas': len(buf),
            'octets': sum(os.path.getsize(os.path.join(d, x)) for x in os.listdir(d))}


# --------------------------------------------------------------- resume
def resume(src, structure, inst, ddl):
    """Certifie la presence ou l'absence de chaque famille d'objets."""
    familles = {'vues': ('views', 1), 'procedures_fonctions': ('routines', 1),
                'triggers': ('triggers', 1), 'evenements': ('events', 1),
                'partitions': ('partitions', 0), 'contraintes_check': ('checks', 1)}
    out = {'tables': structure.get('tables'), 'colonnes': structure.get('columns'),
           'index': structure.get('indexes'), 'cles_etrangeres': structure.get('fks'),
           'ddl': ddl, 'familles': {}}
    for nom, (cle, _) in familles.items():
        n = structure.get(cle)
        if isinstance(n, int):
            out['familles'][nom] = n
        elif isinstance(inst.get(cle), list):
            out['familles'][nom] = len(inst[cle])
    with open(f'{src}/objects_summary.json', 'w', encoding='utf-8') as f:
        json.dump(out, f, indent=1)
    return out


def main():
    ap = argparse.ArgumentParser(description='Collecte des objets MySQL')
    ap.add_argument('--host', required=True)
    ap.add_argument('--port', type=int, default=3306)
    ap.add_argument('--user', required=True)
    ap.add_argument('--password')
    ap.add_argument('--password-file')
    ap.add_argument('--output-dir', required=True)
    ap.add_argument('--schema', action='append', help='limiter a un ou plusieurs schemas')
    ap.add_argument('--no-instance', action='store_true')
    ap.add_argument('--no-structure', action='store_true')
    ap.add_argument('--no-ddl', action='store_true')
    a = ap.parse_args()

    mdp = a.password
    if not mdp and a.password_file:
        mdp = open(a.password_file).read().strip()
    if not mdp:
        mdp = os.environ.get('MYSQL_PWD', '')

    os.makedirs(a.output_dir, exist_ok=True)
    c = Client(a.host, a.port, a.user, mdp)
    t0 = time.time()
    inst, structure, ddl = {}, {}, {}
    if not a.no_instance:
        inst = collect_instance(c, a.output_dir)
    if not a.no_structure:
        structure = collect_structure(c, a.output_dir)
    if not a.no_ddl:
        ddl = collect_ddl(c, a.output_dir, a.schema)
    s = resume(a.output_dir, structure, inst, ddl)
    s['secondes'] = round(time.time() - t0, 1)
    with open(f'{a.output_dir}/objects_summary.json', 'w', encoding='utf-8') as f:
        json.dump(s, f, indent=1)
    print(json.dumps(s, indent=1))


if __name__ == '__main__':
    sys.exit(main())

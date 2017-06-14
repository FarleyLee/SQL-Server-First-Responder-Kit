SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
GO

IF OBJECT_ID('dbo.sp_AllNightLog_Setup') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_AllNightLog_Setup AS RETURN 0;')
GO


ALTER PROCEDURE dbo.sp_AllNightLog_Setup
	  @RPOSeconds BIGINT = 30,
	  @BackupPath NVARCHAR(MAX) = N'D:\Backup',
	  @RunSetup BIT = 0,
	  @UpdateSetup BIT = 0,
	  @Debug BIT = 0,
	  @Help BIT = 0,
	  @VersionDate DATETIME = NULL OUTPUT
WITH RECOMPILE
AS
SET NOCOUNT ON;

BEGIN;


IF @Help = 1

BEGIN

	PRINT '		
		/*


		sp_AllNightLog_Setup from http://FirstResponderKit.org
		
		This script sets up a database, tables, rows, and jobs for sp_AllNightLog, including:

		* Creates a database
			* Right now it''s hard-coded to use msdbCentral, that might change later
	
		* Creates tables in that database!
			* dbo.configuration
				* Hold variables used by stored proc to make runtime decicions
					* RPO: Seconds, how often we look for databases that need log backups
					* Backup Path: The path we feed to Ola H''s backup proc
			* dbo.backup_worker
				* Holds list of databases and some information that helps our Agent jobs figure out if they need to take another log backup
	
		 * Creates agent jobs
			* 1 job that polls sys.databases for new entries
			* 10 jobs that run to take log backups
			 * Based on a queue table
			 * Requires Ola Hallengren''s Database Backup stored proc
	
		To learn more, visit http://FirstResponderKit.org where you can download new
		versions for free, watch training videos on how it works, get more info on
		the findings, contribute your own code, and more.
	
		Known limitations of this version:
		 - Only Microsoft-supported versions of SQL Server. Sorry, 2005 and 2000! And really, maybe not even anything less than 2016. Heh.
		 - The repository database name is hard-coded to msdbCentral.
	
		Unknown limitations of this version:
		 - None.  (If we knew them, they would be known. Duh.)
	
	     Changes - for the full list of improvements and fixes in this version, see:
	     https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/
	
	
		Parameter explanations:
	
		  @RunSetup	BIT, defaults to 0. When this is set to 1, it will run the setup portion to create database, tables, and worker jobs.
		  @UpdateSetup BIT, defaults to 0. When set to 1, will update existing configs for RPO and database backup paths.
		  @RPOSeconds BIGINT, defaults to 30. Value in seconds you want to use to determine if a new log backup needs to be taken.
		  @BackupPath NVARCHAR(MAX), defaults to = ''D:\Backup''. You 99.99999% will need to change this path to something else. This tells Ola''s job where to put backups.
		  @Debug BIT, defaults to 0. Whent this is set to 1, it prints out dynamic SQL commands
	
	    Sample call:
		EXEC dbo.sp_AllNightLog_Setup
			@RunSetup = 1,
			@RPOSeconds = 30,
			@BackupPath = N''M:\MSSQL\Backup'',
			@Debug = 1


		For more documentation: https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/
	
	    MIT License
		
		Copyright (c) 2017 Brent Ozar Unlimited
	
		Permission is hereby granted, free of charge, to any person obtaining a copy
		of this software and associated documentation files (the "Software"), to deal
		in the Software without restriction, including without limitation the rights
		to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
		copies of the Software, and to permit persons to whom the Software is
		furnished to do so, subject to the following conditions:
	
		The above copyright notice and this permission notice shall be included in all
		copies or substantial portions of the Software.
	
		THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
		IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
		FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
		AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
		LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
		OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
		SOFTWARE.


		*/';

RETURN
END /* IF @Help = 1 */


SET NOCOUNT ON;

DECLARE @Version VARCHAR(30);
SET @Version = '1.0';
SET @VersionDate = '20170611';

DECLARE	@database NVARCHAR(128) = NULL; --Holds the database that's currently being processed
DECLARE @error_number INT = NULL; --Used for TRY/CATCH
DECLARE @error_severity INT; --Used for TRY/CATCH
DECLARE @error_state INT; --Used for TRY/CATCH
DECLARE @msg NVARCHAR(4000) = N''; --Used for RAISERROR
DECLARE @rpo INT; --Used to hold the RPO value in our configuration table
DECLARE @backup_path NVARCHAR(MAX); --Used to hold the backup path in our configuration table
DECLARE @db_sql NVARCHAR(MAX) = N''; --Used to hold the dynamic SQL to create msdbCentral
DECLARE @tbl_sql NVARCHAR(MAX) = N''; --Used to hold the dynamic SQL that creates tables in msdbCentral
DECLARE @database_name NVARCHAR(256) = N'msdbCentral'; --Used to hold the name of the database we create to centralize data
													   --Right now it's hardcoded to msdbCentral, but I made it dynamic in case that changes down the line


/*These variables control the loop to create jobs*/
DECLARE @job_sql NVARCHAR(MAX) = N''; --Used to hold the dynamic SQL that creates Agent jobs
DECLARE @counter INT = 0; --For looping to create 10 Agent jobs
DECLARE @job_name NVARCHAR(MAX) = N'''sp_AllNightLog Backups Job 0'''; --Name of log backup job
DECLARE @job_description NVARCHAR(MAX) = N'''This is a worker for the purposes of taking log backups from msdbCentral.dbo.backup_worker queue table.'''; --Job description
DECLARE @job_category NVARCHAR(MAX) = N'''Database Maintenance'''; --Job category
DECLARE @job_owner NVARCHAR(128) = QUOTENAME(SUSER_SNAME(0x01), ''''); -- Admin user/owner
DECLARE @job_command NVARCHAR(MAX) = N'''EXEC sp_AllNightLog @Backup = 1'''; --Command the Agent job will run


/*

Sanity check some variables

*/


/*

Should be a positive number

*/

IF (@RPOSeconds < 0)

		BEGIN
			RAISERROR('Please choose a positive number for @RPOSeconds', 0, 1) WITH NOWAIT;

			RETURN;
		END


/*

Probably shouldn't be more than 4 hours

*/

IF (@RPOSeconds >= 14400)
		BEGIN

			RAISERROR('If your RPO is really 4 hours, perhaps you''d be interested in a more modest recovery model, like SIMPLE?', 0, 1) WITH NOWAIT;

			RETURN;
		END

/*

Basic path sanity checks

*/

IF  (@BackupPath NOT LIKE '[c-zC-Z]:\%') --Local path, don't think anyone has A or B drives
AND (@BackupPath NOT LIKE '\\[a-zA-Z]%\%') --UNC path
AND (@BackupPath NOT LIKE '\\[1-9][1-9][1-9].[1-9][1-9][1-9].[1-9][1-9][1-9].[1-9][1-9][1-9]%\%') --IP address?!
	
		BEGIN 		
				RAISERROR('Are you sure that''s a real path?', 0, 1) WITH NOWAIT
				
				RETURN;
		END 


IF @UpdateSetup = 1
	GOTO UpdateConfigs;

IF @RunSetup = 1
BEGIN
		BEGIN TRY

			BEGIN 
			

				/*
				
				First check to see if Agent is running -- we'll get errors if it's not
				
				*/
				
				
				IF EXISTS (
							SELECT 1
							FROM sys.dm_server_services
							WHERE servicename LIKE 'SQL Server Agent%'
							AND status_desc = 'Stopped'		
						  )
					
					BEGIN
		
						RAISERROR('SQL Server Agent is not currently running -- it needs to be enabled to add backup worker jobs and the new database polling job', 0, 1) WITH NOWAIT;
						
						RETURN;
		
					END;
		

			ELSE
		

				BEGIN


						/*
						
						Check to see if the database exists

						*/
 
						RAISERROR('Checking for msdbCentral', 0, 1) WITH NOWAIT;

						SET @db_sql += N'

							IF DATABASEPROPERTYEX(' + QUOTENAME(@database_name, '''') + ', ''Status'') IS NULL

								BEGIN

									RAISERROR(''Creating msdbCentral'', 0, 1) WITH NOWAIT;

									CREATE DATABASE ' + QUOTENAME(@database_name) + ';
									
									ALTER DATABASE ' + QUOTENAME(@database_name) + ' SET RECOVERY FULL;
								
								END

							';


							IF @Debug = 1
								BEGIN 
									RAISERROR(@db_sql, 0, 1) WITH NOWAIT;
								END; 


							IF @db_sql IS NULL
								BEGIN
									RAISERROR('@db_sql is NULL for some reason', 0, 1) WITH NOWAIT;
								END; 


							EXEC sp_executesql @db_sql; 


						/*
						
						Check for tables and stuff

						*/

						
						RAISERROR('Checking for tables in msdbCentral', 0, 1) WITH NOWAIT;

							SET @tbl_sql += N'
							
									USE ' + QUOTENAME(@database_name) + '
									
									
									IF OBJECT_ID(''' + QUOTENAME(@database_name) + '.dbo.configuration'') IS NULL
									
										BEGIN
										
										RAISERROR(''Creating table dbo.configuration'', 0, 1) WITH NOWAIT;
											
											CREATE TABLE dbo.configuration (
																			database_name NVARCHAR(256), 
																			configuration_name NVARCHAR(512), 
																			configuration_description NVARCHAR(512), 
																			configuration_setting NVARCHAR(MAX)
																			);
											
										END
										
									ELSE 
										
										BEGIN
											
											
											RAISERROR(''Configuration table exists, truncating'', 0, 1) WITH NOWAIT;
										
											
											TRUNCATE TABLE dbo.configuration

										
										END


											RAISERROR(''Inserting configuration values'', 0, 1) WITH NOWAIT;

											
											INSERT dbo.configuration (database_name, configuration_name, configuration_description, configuration_setting) 
															  VALUES (''all'', ''log backup frequency'', ''The length of time in second between log backups.'', ''' + CONVERT(NVARCHAR(10), @RPOSeconds) + ''');
											
											
											INSERT dbo.configuration (database_name, configuration_name, configuration_description, configuration_setting) 
															  VALUES (''all'', ''log backup path'', ''The path to which Log Backups should go.'', ''' + @BackupPath + ''');									
									
									
									
									IF OBJECT_ID(''' + QUOTENAME(@database_name) + '.dbo.backup_worker'') IS NULL
										
										BEGIN
										
										
											RAISERROR(''Creating table dbo.backup_worker'', 0, 1) WITH NOWAIT;
											
												CREATE TABLE dbo.backup_worker (
																				id INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED, 
																				database_name NVARCHAR(256), 
																				last_log_backup_start_time DATETIME DEFAULT ''19000101'', 
																				last_log_backup_finish_time DATETIME DEFAULT ''99991231'', 
																				is_started BIT DEFAULT 0, 
																				is_completed BIT DEFAULT 0, 
																				error_number INT DEFAULT NULL, 
																				last_error_date DATETIME DEFAULT NULL
																				);
											
										END;
									

											
											RAISERROR(''Inserting databases for backups'', 0, 1) WITH NOWAIT;
									
											INSERT ' + QUOTENAME(@database_name) + '.dbo.backup_worker (database_name) 
											SELECT d.name
											FROM sys.databases d
											WHERE NOT EXISTS (
												SELECT * 
												FROM msdbCentral.dbo.backup_worker bw
												WHERE bw.database_name = d.name
															)
											AND d.database_id > 4;
									
									';

							
							IF @Debug = 1
								BEGIN 
									RAISERROR(@tbl_sql, 0, 1) WITH NOWAIT;
								END; 

							
							IF @tbl_sql IS NULL
								BEGIN
									RAISERROR('@tbl_sql is NULL for some reason', 0, 1) WITH NOWAIT;
								END; 


							EXEC sp_executesql @tbl_sql;
		
		
		
		/*
		
		Add Jobs
		
		*/
		

		
		/*
		
		Look for our ten second schedule -- all jobs use this to restart themselves if they fail

		Fun fact: you can add the same schedule name multiple times, so we don't want to just stick it in there
		
		*/


		RAISERROR('Checking for ten second schedule', 0, 1) WITH NOWAIT;

			IF NOT EXISTS (
							SELECT 1 
							FROM msdb.dbo.sysschedules 
							WHERE name = 'ten_seconds'
						  )
			
				BEGIN
					
					
					RAISERROR('Creating ten second schedule', 0, 1) WITH NOWAIT;

					
					EXEC msdb.dbo.sp_add_schedule    @schedule_name= ten_seconds, 
													 @enabled = 1, 
													 @freq_type = 4, 
													 @freq_interval = 1, 
													 @freq_subday_type = 2,  
													 @freq_subday_interval = 10, 
													 @freq_relative_interval = 0, 
													 @freq_recurrence_factor = 0, 
													 @active_start_date = 19900101, 
													 @active_end_date = 99991231, 
													 @active_start_time = 0, 
													 @active_end_time = 235959;
				
				END;
		
			
			/*
			
			Look for Pollster job -- this job sets up our watcher for new databases
			
			*/

			
			RAISERROR('Checking for pollster job', 0, 1) WITH NOWAIT;

			
			IF NOT EXISTS (
							SELECT 1 
							FROM msdb.dbo.sysjobs 
							WHERE name = 'pollster_00'
						  )
		
				
				BEGIN
					
					
					RAISERROR('Creating pollster job', 0, 1) WITH NOWAIT;

						
						EXEC msdb.dbo.sp_add_job @job_name = sp_AllNightLog_PollForNewDatabases, 
												 @description = 'This is a worker for the purposes of polling sys.databases for new entries to insert to the worker queue table.', 
												 @category_name = 'Database Maintenance', 
												 @owner_login_name = 'sa',
												 @enabled = 0;
					
					
					
					RAISERROR('Adding job step', 0, 1) WITH NOWAIT;

						
						EXEC msdb.dbo.sp_add_jobstep @job_name = sp_AllNightLog_PollForNewDatabases, 
													 @step_name = sp_AllNightLog_PollForNewDatabases, 
													 @subsystem = 'TSQL', 
													 @command = 'EXEC sp_AllNightLog @PollForNewDatabases = 1';
					
					
					
					RAISERROR('Adding job server', 0, 1) WITH NOWAIT;

						
						EXEC msdb.dbo.sp_add_jobserver @job_name = sp_AllNightLog_PollForNewDatabases;

					
									
					RAISERROR('Attaching schedule', 0, 1) WITH NOWAIT;
		
						
						EXEC msdb.dbo.sp_attach_schedule @job_name = sp_AllNightLog_PollForNewDatabases, 
														 @schedule_name = ten_seconds;
		
				
				END;	
				

				/*
				
				This section creates 10 worker jobs to take log backups with

				They work in a queue

				It's queuete
				
				*/


				RAISERROR('Checking for sp_AllNightLog backup jobs', 0, 1) WITH NOWAIT;
				
					
					SELECT @counter = COUNT(*) + 1 
					FROM msdb.dbo.sysjobs 
					WHERE name LIKE '%sp_AllNightLog_Backup_%';

					SET @msg = 'Found ' + CONVERT(NVARCHAR(10), (@counter - 1)) + ' backup jobs -- ' +  CASE WHEN @counter < 10 THEN + 'starting loop!'
																											 WHEN @counter >= 10 THEN 'skipping loop!'
																											 ELSE 'Oh woah something weird happened!'
																										END;	

					RAISERROR(@msg, 0, 1) WITH NOWAIT;

					
							WHILE @counter < 11

							
								BEGIN

									
										RAISERROR('Setting job name', 0, 1) WITH NOWAIT;

											SET @job_name = N'sp_AllNightLog_Backup_' + 
																				CASE 
																				WHEN @counter < 10 THEN N'0' + CONVERT(NVARCHAR(10), @counter)
																				WHEN @counter >= 10 THEN CONVERT(NVARCHAR(10), @counter)
																				END; 
							
										
										RAISERROR('Setting @job_sql', 0, 1) WITH NOWAIT;

										
											SET @job_sql = N'
							
											EXEC msdb.dbo.sp_add_job @job_name = ' + @job_name + ', 
																	 @description = ' + @job_description + ', 
																	 @category_name = ' + @job_category + ', 
																	 @owner_login_name = ' + @job_owner + ',
																	 @enabled = 0;
								  
											
											EXEC msdb.dbo.sp_add_jobstep @job_name = ' + @job_name + ', 
																		 @step_name = ' + @job_name + ', 
																		 @subsystem = ''TSQL'', 
																		 @command = ' + @job_command + ';
								  
											
											EXEC msdb.dbo.sp_add_jobserver @job_name = ' + @job_name + ';
											
											
											EXEC msdb.dbo.sp_attach_schedule  @job_name = ' + @job_name + ', 
																			  @schedule_name = ten_seconds;
											
											';
							
										
										SET @counter += 1;

										
											IF @Debug = 1
												BEGIN 
													RAISERROR(@job_sql, 0, 1) WITH NOWAIT;
												END; 		

		
											IF @job_sql IS NULL
											BEGIN
												RAISERROR('@job_sql is NULL for some reason', 0, 1) WITH NOWAIT;
											END; 


										EXEC sp_executesql @job_sql;

							
								END;		

		
		RAISERROR('Setup complete!', 0, 1) WITH NOWAIT;
		
			END; --End for the Agent job creation

		END;--End for Database and Table creation

	END TRY

	BEGIN CATCH


		SELECT @msg = N'Error occurred during setup: ' + CONVERT(NVARCHAR(10), ERROR_NUMBER()) + ', error message is ' + ERROR_MESSAGE(), 
			   @error_severity = ERROR_SEVERITY(), 
			   @error_state = ERROR_STATE();
		
		RAISERROR(@msg, @error_severity, @error_state) WITH NOWAIT;


		WHILE @@TRANCOUNT > 0
			ROLLBACK;

	END CATCH;

END  /* IF @RunSetup = 1 */

RETURN;


UpdateConfigs:

IF @UpdateSetup = 1
	AND (@RPOSeconds IS NULL AND @BackupPath IS NULL)

		BEGIN
			RAISERROR('If you want to update configuration settings, they can''t be NULL. Please Make sure @RPOSeconds or @BackupPath has a value', 0, 1) WITH NOWAIT;

			RETURN;
		END

			IF OBJECT_ID('msdbCentral.dbo.configuration') IS NOT NULL
	
				BEGIN
					
					RAISERROR('Attempting to update RPO setting', 0, 1) WITH NOWAIT;

					BEGIN TRY

						
						IF @RPOSeconds IS NOT NULL

							BEGIN

								UPDATE c
										SET c.configuration_setting = CONVERT(NVARCHAR(10), @RPOSeconds)
								FROM msdbCentral.dbo.configuration AS c
								WHERE c.configuration_name = N'log backup frequency'

							END

						
						IF @BackupPath IS NOT NULL

							BEGIN

								UPDATE c
										SET c.configuration_setting = @BackupPath
								FROM msdbCentral.dbo.configuration AS c
								WHERE c.configuration_name = N'log backup path'


							END


					END TRY


					BEGIN CATCH


						SELECT @error_number = ERROR_NUMBER(), 
							   @error_severity = ERROR_SEVERITY(), 
							   @error_state = ERROR_STATE();

						SELECT @msg = N'Error updating configuration setting, error number is ' + CONVERT(NVARCHAR(10), ERROR_NUMBER()) + ', error message is ' + ERROR_MESSAGE(), 
							   @error_severity = ERROR_SEVERITY(), 
							   @error_state = ERROR_STATE();
						
						RAISERROR(@msg, @error_severity, @error_state) WITH NOWAIT;


					END CATCH


					RETURN


				END --End updates to configuration table


END; -- Final END for stored proc
GO
